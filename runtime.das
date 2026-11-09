options gen2
module runtime

require reader public
require printer public
require daslib/fio
require line_input public
require memory public
require daslib/defer

def chop_line(s : string) : string {
    return s |> trim_suffix("\n") |> trim_suffix("\r")
}

def equal_items(vm : VM; xs, ys : array<Val>) : bool {
    if (length(xs) != length(ys)) return false
    for (x, y in xs, ys) {
        if (!equal(vm, x, y)) return false
    }
    return true
}

def equal_views(vm : VM; a, b : SequenceView) : bool {
    if (a.count != b.count) return false
    if (a.owner == b.owner && a.start == b.start) return true
    match (vm.values[a.owner].data, vm.values[b.owner].data) {
        (Data(list = xs) | Data(vector = xs), Data(list = ys) | Data(vector = ys)) => $ {
            if (a.start < 0 || a.start > length(xs) || a.count < 0 || a.count > length(xs) - a.start ||
                b.start < 0 || b.start > length(ys) || b.count < 0 || b.count > length(ys) - b.start) {
                panic("equal_views: invalid sequence interval")
            }
            if (a.count == 0) return true
            // Both complete intervals are checked above. equal takes a const VM:
            // recursive comparisons never resize arrays, evaluate Lisp or collect.
            // Pointers stay local to this immutable comparison.
            unsafe {
                let xp = addr(xs[a.start])
                let yp = addr(ys[b.start])
                for (i in range(a.count)) {
                    if (!equal(vm, xp[i], yp[i])) return false
                }
            }
            return true
        }
        _ => $ { return false }
    }
    return false
}

def equal(vm : VM; a, b : Val) : bool {
    if (a == b) return true
    if ((vm.values[a].data is list_tail || vm.values[b].data is list_tail) && sequential(vm, a) && sequential(vm, b)) {
        return equal_views(vm, sequence_view(vm, a), sequence_view(vm, b))
    }
    match (vm.values[a].data, vm.values[b].data) {
        // Borrow payloads: equality never allocates into the VM arena.
        (Data(list = xs) | Data(vector = xs), Data(list = ys) | Data(vector = ys)) => $ {
            return equal_items(vm, xs, ys)
        }
        (Data(nil_), Data(nil_)) => $ { return true }
        (Data(boolean = x), Data(boolean = y)) => $ { return x == y }
        (Data(number = x), Data(number = y)) => $ { return x == y }
        (Data(text = x), Data(text = y)) => $ { return x == y }
        (Data(symbol = x), Data(symbol = y)) => $ { return x == y }
        (Data(keyword = x), Data(keyword = y)) => $ { return x == y }
        (Data(map_ = x), Data(map_ = y)) => $ {
            if (length(x) != length(y)) return false
            for (k, v in keys(x), values(x)) {
                let other = y?[k] ?? -1
                if (other < 0 || !equal(vm, v, other)) return false
            }
            return true
        }
        _ => $ { return false }
    }
    return false
}

def arity(var vm : VM; name : string; count, lo, hi : int) : bool {
    if (count >= lo && (hi < 0 || count <= hi)) return true
    fail(vm, "{name}: wrong number of arguments (got {count}, expected {lo}..{hi})")
    return false
}

def numeric(var vm : VM; v : Val) : int64 {
    if (vm.values[v].data is number) return vm.values[v].data as number
    fail(vm, "expected a number")
    return 0l
}

def string_value(var vm : VM; v : Val) : string {
    if (vm.values[v].data is text) return vm.values[v].data as text
    fail(vm, "expected a string")
    return ""
}

def is_macro(vm : VM; v : Val) : bool =>
    vm.values[v].data is function_ && (vm.values[v].data as function_).macro_

def callable(vm : VM; v : Val) : bool => vm.values[v].data is function_ || vm.values[v].data is native

def copy_value(var vm : VM; v : Val) : Val {
    let meta = vm.values[v].meta
    // Clone the active owning payload explicitly. Lisp copies share child
    // handles, never array/table storage.
    var result = NIL
    match (vm.values[v].data) {
        Data(list = source) => $ {
            var inscope xs := source
            result = list(vm, xs)
        }
        Data(list_tail = source) => $ {
            let tail = source
            result = alloc(vm, Data(list_tail = tail))
        }
        Data(vector = source) => $ {
            var inscope xs := source
            result = vector(vm, xs)
        }
        Data(map_ = source) => $ {
            var inscope entries := source
            result = alloc(vm, Data(map_ <- entries))
        }
        Data(function_ = source) => $ {
            let closure = source
            result = alloc(vm, Data(function_ = closure))
        }
        Data(native = source) => $ {
            let name = source
            result = alloc(vm, Data(native = name))
        }
        _ => $ { return fail(vm, "cannot copy this value") }
    }
    vm.values[result].meta = meta
    return result
}

def validate_params(var vm : VM; params : Val) : bool {
    if (!sequential(vm, params)) { fail(vm, "fn*: expected parameter list or vector"); return false }
    var inscope ps <- items(vm, params)
    var inscope seen : table<string; bool>
    for (i in range(length(ps))) {
        let name = symbol_name(vm, ps[i])
        if (name is none) { fail(vm, "fn*: expected a parameter symbol"); return false }
        let p = unwrap(name)
        if (key_exists(seen, p)) { fail(vm, "fn*: duplicate parameter"); return false }
        if (p == "&") {
            if (i != length(ps) - 2 || symbol_matches(vm, ps[i + 1], "&")) {
                fail(vm, "fn*: & must precede one final rest parameter")
                return false
            }
        }
        seen[p] = true
    }
    return true
}

def bind_call(var vm : VM; f : Closure; args : array<Val>) : int {
    if (!arity(vm, "fn*", length(args), f.fixed_arity, f.has_rest ? -1 : f.fixed_arity)) return -1
    let e = new_env(vm, f.env)
    // Parameter symbols were checked at fn* creation. Binding does not allocate
    // values, so the array can be borrowed until the rest-list is constructed.
    match (vm.values[f.params].data) {
        Data(list = ps) | Data(vector = ps) => $ {
            for (i in range(f.fixed_arity)) {
                set_symbol_binding(vm, e, ps[i], args[i])
            }
        }
        Data(list_tail = _) => $ {
            let view = sequence_view(vm, f.params)
            for (i in range(f.fixed_arity)) {
                set_symbol_binding(vm, e, sequence_at(vm, view, i), args[i])
            }
        }
        _ => $ { return -1 }
    }
    if (f.has_rest) {
        var inscope rest <- args |> skip(f.fixed_arity)
        let value = list(vm, rest)
        set_symbol_binding(vm, e, f.rest_symbol, value)
    }
    return e
}

def make_closure(var vm : VM; params, body : Val; env : int) : Val {
    if (!validate_params(vm, params)) return NIL
    var inscope ps <- items(vm, params)
    let has_rest = length(ps) >= 2 && symbol_matches(vm, ps[length(ps) - 2], "&")
    let f = Closure(params = params, body = body, env = env,
        fixed_arity = length(ps) - (has_rest ? 2 : 0), has_rest = has_rest,
        rest_symbol = has_rest ? back(ps) : NIL)
    return alloc(vm, Data(function_ = f))
}

def quasiquote(var vm : VM; ast : Val) : Val {
    if (sequential(vm, ast)) {
        let is_vector = vm.values[ast].data is vector
        var inscope xs <- items(vm, ast)
        if (!is_vector && !empty(xs) && symbol_matches(vm, xs[0], "unquote")) {
            if (length(xs) != 2) return fail(vm, "unquote expects one form")
            return xs[1]
        }
        var result = list(vm, array<Val>())
        for (offset in range(length(xs))) {
            let i = length(xs) - 1 - offset
            let x = xs[i]
            if (list_like(vm, x)) {
                var inscope part <- items(vm, x)
                if (!empty(part) && symbol_matches(vm, part[0], "splice-unquote")) {
                    if (length(part) != 2) return fail(vm, "splice-unquote expects one form")
                    result = list(vm, [symbol(vm, "concat"), part[1], result])
                    continue
                }
            }
            let quoted = quasiquote(vm, x)
            result = list(vm, [symbol(vm, "cons"), quoted, result])
        }
        return is_vector ? list(vm, [symbol(vm, "vec"), result]) : result
    }
    if (vm.values[ast].data is symbol || vm.values[ast].data is map_) {
        return list(vm, [symbol(vm, "quote"), ast])
    }
    return ast
}

// Explicit evaluator loop implements tail calls, including macro expansion.
// Non-tail subexpressions recurse; no host exceptions carry Lisp control flow.
def eval(var vm : VM; initial : Val; initial_env : int = 0) : Val {
    if (vm.thrown >= 0) return NIL
    if (!vm.debug_possible && empty(vm.root_envs)) {
        vm.debug_possible = lookup(vm, initial_env, "DEBUG-EVAL") >= 0
    }
    // Leaves neither recurse nor trigger collection: avoid a root frame and
    // container cleanup for the most common evaluator calls.
    if (!vm.debug_possible) {
        match (vm.values[initial].data) {
            Data(symbol = name) => $ {
                let value = lookup_symbol(vm, initial_env, initial)
                return value < 0 ? fail(vm, "'{name}' not found") : value
            }
            Data(list = _) | Data(list_tail = _) | Data(vector = _) | Data(map_ = _) => $ {}
            _ => $ { return initial }
        }
    }
    return eval_form(vm, initial, initial_env)
}

def eval_form(var vm : VM; initial : Val; initial_env : int) : Val {
    let value_mark = length(vm.root_values)
    let env_mark = length(vm.root_envs)
    var buffers = evaluation_buffers(vm, env_mark)
    assume xs = buffers.expressions
    assume args = buffers.arguments
    push(vm.root_values, initial)
    push(vm.root_envs, initial_env)
    defer() {
        resize(vm.root_values, value_mark)
        resize(vm.root_envs, env_mark)
    }
    var ast = initial
    var env = initial_env
    while (vm.thrown < 0) {
        resize(vm.root_values, value_mark + 1)
        vm.root_values[value_mark] = ast
        vm.root_envs[env_mark] = env
        if (vm.allocations_since_gc >= vm.gc_threshold) { collect(vm) }
        if (vm.debug_possible) {
            let debug = lookup(vm, env, "DEBUG-EVAL")
            if (debug >= 0 && truthy(debug)) { print("EVAL: {pr_str(vm, ast)}\n") }
        }
        match (vm.values[ast].data) {
            Data(symbol = name) => $ {
                let value = lookup_symbol(vm, env, ast)
                return value < 0 ? fail(vm, "'{name}' not found") : value
            }
            Data(vector = source) => $ {
                // eval may grow vm.values: finish the snapshot before recursing.
                var inscope elements := source
                var inscope result : array<Val>
                for (x in elements) {
                    let value = eval(vm, x, env)
                    push(result, value)
                    push(vm.root_values, value)
                    if (vm.thrown >= 0) return NIL
                }
                return vector(vm, result)
            }
            Data(map_ = source) => $ {
                var inscope entries := source
                for (value in values(entries)) {
                    value = eval(vm, value, env)
                    push(vm.root_values, value)
                    if (vm.thrown >= 0) return NIL
                }
                return alloc(vm, Data(map_ <- entries))
            }
            Data(list = source) => $ { xs := source }
            Data(list_tail = _) => $ { copy_items(vm, ast, xs) }
            _ => $ { return ast }
        }
        resize(args, 0)
        if (empty(xs)) return ast
        let name = unwrap_or(symbol_name(vm, xs[0]), "")
        match (name) {
            "def!" | "defmacro!" => $ {
                if (!arity(vm, name, length(xs) - 1, 2, 2)) return NIL
                let key = xs[1]
                if (!(vm.values[key].data is symbol)) return fail(vm, "{name}: expected a symbol")
                var value = eval(vm, xs[2], env)
                if (vm.thrown >= 0) return NIL
                if (name == "defmacro!") {
                    if (!(vm.values[value].data is function_)) return fail(vm, "defmacro!: expected a Lisp function")
                    value = copy_value(vm, value)
                    (vm.values[value].data as function_).macro_ = true
                }
                set_symbol_binding(vm, env, key, value)
                return value
            }
            "let*" => $ {
                if (!arity(vm, name, length(xs) - 1, 2, 2)) return NIL
                var inscope bindings <- items(vm, xs[1])
                if (vm.thrown >= 0) return NIL
                if (length(bindings) % 2 != 0) return fail(vm, "let*: expected binding pairs")
                env = new_env(vm, env)
                vm.root_envs[env_mark] = env
                for (pair in range(length(bindings) / 2)) {
                    let key = bindings[pair * 2]
                    if (!(vm.values[key].data is symbol)) return fail(vm, "let*: expected a symbol")
                    let value = eval(vm, bindings[pair * 2 + 1], env)
                    if (vm.thrown >= 0) return NIL
                    set_symbol_binding(vm, env, key, value)
                }
                ast = xs[2]
                continue
            }
            "quote" | "quasiquote" | "quasiquoteexpand" | "macroexpand" => $ {
                if (!arity(vm, name, length(xs) - 1, 1, 1)) return NIL
                if (name == "quote") return xs[1]
                if (name == "macroexpand") return macroexpand(vm, xs[1], env)
                ast = quasiquote(vm, xs[1])
                if (name == "quasiquoteexpand") return ast
                continue
            }
            "do" => $ {
                if (length(xs) == 1) return NIL
                for (i in range(1, length(xs) - 1)) {
                    eval(vm, xs[i], env)
                    if (vm.thrown >= 0) return NIL
                }
                ast = back(xs)
                continue
            }
            "if" => $ {
                if (!arity(vm, name, length(xs) - 1, 2, 3)) return NIL
                let cond = eval(vm, xs[1], env)
                if (vm.thrown >= 0) return NIL
                if (!truthy(cond) && length(xs) == 3) return NIL
                ast = truthy(cond) ? xs[2] : xs[3]
                continue
            }
            "fn*" => $ {
                if (!arity(vm, name, length(xs) - 1, 2, 2)) return NIL
                return make_closure(vm, xs[1], xs[2], env)
            }
            "try*" => $ {
                if (!arity(vm, name, length(xs) - 1, 1, 2)) return NIL
                if (length(xs) == 2) { ast = xs[1]; continue }
                var inscope handler <- items(vm, xs[2])
                if (vm.thrown >= 0) return NIL
                if (length(handler) != 3 || !symbol_matches(vm, handler[0], "catch*") || is_none(symbol_name(vm, handler[1]))) {
                    return fail(vm, "try*: expected (catch* symbol body)")
                }
                let result = eval(vm, xs[1], env)
                if (vm.thrown < 0) return result
                let error = vm.thrown
                vm.thrown = -1
                env = new_env(vm, env)
                set_symbol_binding(vm, env, handler[1], error)
                ast = handler[2]
                continue
            }
            _ => $ {}
        }
        let f = eval(vm, xs[0], env)
        if (vm.thrown >= 0) return NIL
        push(vm.root_values, f)
        if (is_macro(vm, f)) {
            for (i in range(1, length(xs))) { push(args, xs[i]) }
            ast = apply(vm, f, args)
            continue
        }
        for (i in range(1, length(xs))) {
            let value = eval(vm, xs[i], env)
            push(args, value)
            push(vm.root_values, value)
            if (vm.thrown >= 0) return NIL
        }
        match (vm.values[f].data) {
            Data(function_ = source) => $ {
                let closure = source
                env = bind_call(vm, closure, args)
                ast = closure.body
                continue
            }
            Data(native = source) => $ {
                let native = source
                // This evaluator frame already roots f and all arguments.
                return native_call(vm, native, args)
            }
            _ => $ { return fail(vm, "expected a function") }
        }
    }
    return NIL
}

def macroexpand(var vm : VM; initial : Val; env : int) : Val {
    let value_mark = length(vm.root_values)
    let env_mark = length(vm.root_envs)
    push(vm.root_values, initial)
    push(vm.root_envs, env)
    defer() {
        resize(vm.root_values, value_mark)
        resize(vm.root_envs, env_mark)
    }
    var ast = initial
    while (vm.thrown < 0 && list_like(vm, ast)) {
        vm.root_values[value_mark] = ast
        var inscope xs <- items(vm, ast)
        if (empty(xs)) return ast
        let name = symbol_name(vm, xs[0])
        if (name is none) return ast
        let f = lookup_symbol(vm, env, xs[0])
        if (f < 0 || !is_macro(vm, f)) return ast
        var inscope args <- xs |> skip(1)
        ast = apply(vm, f, args)
    }
    return ast
}

def apply(var vm : VM; f : Val; args : array<Val>) : Val {
    if (vm.thrown >= 0) return NIL
    if (vm.values[f].data is native) {
        let native = vm.values[f].data as native
        if (!native_evaluates(native.op)) return native_call(vm, native, args)
    }
    // defer belongs to its lexical scope, including returns before its call.
    // Keep this cleanup in a separate block: the native fast path above never
    // initializes value_mark and must not clear the caller's roots on return.
    {
        let value_mark = length(vm.root_values)
        push(vm.root_values, f)
        push(vm.root_values, args)
        defer() { resize(vm.root_values, value_mark) }
        match (vm.values[f].data) {
            Data(native = source) => $ {
                let name = source
                return native_call(vm, name, args)
            }
            Data(function_ = source) => $ {
                let closure = source
                let env = bind_call(vm, closure, args)
                return eval(vm, closure.body, env)
            }
            _ => $ { return fail(vm, "expected a function") }
        }
    }
    return NIL
}

def native_evaluates(op : NativeOp) : bool {
    return match (op) {
        NativeOp.apply_ | NativeOp.map_ | NativeOp.swap | NativeOp.eval_ => true
        _ => false
    }
}

def native_arity(op : NativeOp) : int2 {
    return match (op) {
        NativeOp.list_ | NativeOp.vector_ | NativeOp.hash_map | NativeOp.concat | NativeOp.pr_str | NativeOp.str_ | NativeOp.prn | NativeOp.println | NativeOp.add | NativeOp.multiply => int2(0, -1)
        NativeOp.subtract | NativeOp.divide => int2(1, -1)
        NativeOp.assoc => int2(3, -1)
        NativeOp.dissoc | NativeOp.conj | NativeOp.apply_ | NativeOp.swap => int2(2, -1)
        NativeOp.equal_ | NativeOp.less | NativeOp.less_equal | NativeOp.greater | NativeOp.greater_equal | NativeOp.cons | NativeOp.nth | NativeOp.get_ | NativeOp.contains | NativeOp.map_ | NativeOp.reset | NativeOp.with_meta => int2(2, 2)
        NativeOp.time_ms => int2(0, 0)
        _ => int2(1, 1)
    }
}

// Read-only helpers borrow payloads only until they return. Allocating a
// result (e.g. a number for count) happens after the borrow has ended.
def collection_size(vm : VM; v : Val) : int {
    return match (vm.values[v].data) {
        Data(nil_) => 0
        Data(list = xs) | Data(vector = xs) => length(xs)
        Data(list_tail = _) => sequence_view(vm, v).count
        Data(text = s) => length(s)
        Data(map_ = entries) => length(entries)
        _ => -1
    }
}

def first_item(var vm : VM; v : Val) : Val {
    match (vm.values[v].data) {
        Data(nil_) => $ { return NIL }
        Data(list = xs) | Data(vector = xs) => $ { return empty(xs) ? NIL : xs[0] }
        Data(list_tail = _) => $ {
            let view = sequence_view(vm, v)
            return view.count == 0 ? NIL : sequence_at(vm, view, 0)
        }
        _ => $ { return fail(vm, "expected a list or vector") }
    }
    return NIL
}

def nth_item(var vm : VM; v : Val; index : int64) : Val {
    match (vm.values[v].data) {
        Data(list = xs) | Data(vector = xs) => $ {
            if (index < 0 || index >= int64(length(xs))) return fail(vm, "nth: index out of range")
            return xs[int(index)]
        }
        Data(list_tail = _) => $ {
            let view = sequence_view(vm, v)
            if (index < 0 || index >= int64(view.count)) return fail(vm, "nth: index out of range")
            return sequence_at(vm, view, int(index))
        }
        _ => $ { return fail(vm, "expected a list or vector") }
    }
    return NIL
}

def native_call(var vm : VM; native : NativeFn; args : array<Val>) : Val {
    let op = native.op
    let name = native.name
    let bounds = native.arity
    if (!arity(vm, name, length(args), bounds.x, bounds.y)) return NIL
    let a = empty(args) ? NIL : args[0]
    let b = length(args) < 2 ? NIL : args[1]
    match (op) {
        NativeOp.add | NativeOp.subtract | NativeOp.multiply | NativeOp.divide => $ {
            var result = op == NativeOp.multiply ? 1l : 0l
            var start = 0
            if (op == NativeOp.subtract || op == NativeOp.divide) { result = numeric(vm, a); start = 1 }
            if (op == NativeOp.subtract && length(args) == 1) { result = -result }
            for (i in range(start, length(args))) {
                let n = numeric(vm, args[i])
                if (vm.thrown >= 0) return NIL
                match (op) {
                    NativeOp.add => $ { result += n }
                    NativeOp.subtract => $ { result -= n }
                    NativeOp.multiply => $ { result *= n }
                    _ => $ {
                        if (n == 0l) return fail(vm, "division by zero")
                        if (result == -9223372036854775807l - 1l && n == -1l) return fail(vm, "integer division overflow")
                        result /= n
                    }
                }
            }
            return number(vm, result)
        }
        NativeOp.equal_ => $ { return boolean(equal(vm, a, b)) }
        NativeOp.less | NativeOp.less_equal | NativeOp.greater | NativeOp.greater_equal => $ {
            let x = numeric(vm, a)
            let y = numeric(vm, b)
            return boolean(match (op) { NativeOp.less => x < y; NativeOp.less_equal => x <= y; NativeOp.greater => x > y; _ => x >= y; })
        }
        NativeOp.is_nil => $ { return boolean(a == NIL) }
        NativeOp.is_true => $ { return boolean(a == TRUE) }
        NativeOp.is_false => $ { return boolean(a == FALSE) }
        NativeOp.is_number => $ { return boolean(vm.values[a].data is number) }
        NativeOp.is_string => $ { return boolean(vm.values[a].data is text) }
        NativeOp.is_symbol => $ { return boolean(vm.values[a].data is symbol) }
        NativeOp.is_keyword => $ { return boolean(vm.values[a].data is keyword) }
        NativeOp.is_list => $ { return boolean(list_like(vm, a)) }
        NativeOp.is_vector => $ { return boolean(vm.values[a].data is vector) }
        NativeOp.is_map => $ { return boolean(vm.values[a].data is map_) }
        NativeOp.is_sequential => $ { return boolean(sequential(vm, a)) }
        NativeOp.is_fn => $ { return boolean(callable(vm, a) && !is_macro(vm, a)) }
        NativeOp.is_macro => $ { return boolean(is_macro(vm, a)) }
        NativeOp.is_atom => $ { return boolean(vm.values[a].data is atom) }
        NativeOp.symbol_ => $ { return symbol(vm, string_value(vm, a)) }
        NativeOp.keyword_ => $ { return vm.values[a].data is keyword ? a : keyword(vm, string_value(vm, a)) }
        NativeOp.list_ => $ { var inscope xs : array<Val>; xs := args; return list(vm, xs) }
        NativeOp.vector_ => $ { var inscope xs : array<Val>; xs := args; return vector(vm, xs) }
        NativeOp.hash_map => $ { return make_map(vm, args) }
        NativeOp.vec => $ { var inscope xs <- items(vm, a); return vector(vm, xs) }
        NativeOp.cons => $ {
            var inscope xs <- items(vm, b, true)
            push(xs, a, 0)
            return list(vm, xs)
        }
        NativeOp.concat => $ {
            var inscope xs : array<Val>
            for (arg in args) { var inscope part <- items(vm, arg, true); push(xs, part) }
            return list(vm, xs)
        }
        NativeOp.count_ | NativeOp.is_empty => $ {
            let n = collection_size(vm, a)
            if (n < 0) return fail(vm, "{name}: expected a collection")
            return op == NativeOp.is_empty ? boolean(n == 0) : number(vm, int64(n))
        }
        NativeOp.nth => $ {
            if (!sequential(vm, a)) return fail(vm, "expected a list or vector")
            let i = numeric(vm, b)
            if (vm.thrown >= 0) return NIL
            return nth_item(vm, a, i)
        }
        NativeOp.first_ => $ { return first_item(vm, a) }
        NativeOp.rest => $ { return rest_list(vm, a) }
        NativeOp.conj => $ {
            let is_vector = vm.values[a].data is vector
            var inscope xs <- items(vm, a)
            for (i in range(1, length(args))) {
                if (is_vector) { push(xs, args[i]) } else { push(xs, args[i], 0) }
            }
            return is_vector ? vector(vm, xs) : list(vm, xs)
        }
        NativeOp.seq => $ {
            if (a == NIL) return NIL
            var inscope xs : array<Val>
            if (vm.values[a].data is text) {
                let s = vm.values[a].data as text
                for (i in range(length(s))) { push(xs, text(vm, slice(s, i, i + 1))) }
            } else { xs <- items(vm, a) }
            return empty(xs) ? NIL : list(vm, xs)
        }
        NativeOp.assoc | NativeOp.dissoc => $ {
            if (!(vm.values[a].data is map_)) return fail(vm, "{name}: expected a map")
            if (op == NativeOp.assoc && length(args) % 2 != 1) return fail(vm, "assoc: expected key/value pairs")
            var inscope entries : table<string; Val>
            entries := vm.values[a].data as map_
            var i = 1
            while (i < length(args)) {
                let k = map_key(vm, args[i])
                if (vm.thrown >= 0) return NIL
                if (op == NativeOp.assoc) { entries[k] = args[i + 1]; i += 2 }
                else { erase(entries, k); i++ }
            }
            return alloc(vm, Data(map_ <- entries))
        }
        NativeOp.get_ | NativeOp.contains => $ {
            let k = map_key(vm, b)
            if (vm.thrown >= 0) return NIL
            if (a == NIL) return op == NativeOp.get_ ? NIL : FALSE
            if (!(vm.values[a].data is map_)) return fail(vm, "{name}: expected a map")
            if (op == NativeOp.contains) return boolean(key_exists(vm.values[a].data as map_, k))
            return (vm.values[a].data as map_)?[k] ?? NIL
        }
        NativeOp.keys_ | NativeOp.vals => $ {
            if (!(vm.values[a].data is map_)) return fail(vm, "{name}: expected a map")
            var inscope entries : table<string; Val>
            entries := vm.values[a].data as map_
            var inscope xs : array<Val>
            for (k, v in keys(entries), values(entries)) {
                push(xs, op == NativeOp.vals ? v : (starts_with(k, "s") ? text(vm, slice(k, 1)) : keyword(vm, slice(k, 1))))
            }
            return list(vm, xs)
        }
        NativeOp.pr_str | NativeOp.str_ | NativeOp.prn | NativeOp.println => $ {
            let readable = op == NativeOp.pr_str || op == NativeOp.prn
            let result = join(args, op == NativeOp.str_ ? "" : " ") $(var writer; x) {
                write(writer, pr_str(vm, x, readable))
            }
            if (op == NativeOp.prn || op == NativeOp.println) { print("{result}\n"); return NIL }
            return text(vm, result)
        }
        NativeOp.read_string => $ { let s = string_value(vm, a); return vm.thrown < 0 ? read_str(vm, s) : NIL }
        NativeOp.readline => $ {
            let prompt = string_value(vm, a)
            if (vm.thrown >= 0) return NIL
            print(prompt)
            fflush(fstdout())
            let line = read_line(fstdin())
            return line is none ? NIL : text(vm, chop_line(unwrap(line)))
        }
        NativeOp.slurp => $ {
            let path = string_value(vm, a)
            if (vm.thrown >= 0) return NIL
            let f = fopen(path, "rb")
            if (f == null) return fail(vm, "slurp: cannot open '{path}'")
            let content = fread(f)
            fclose(f)
            return text(vm, content)
        }
        NativeOp.eval_ => $ { return eval(vm, a, 0) }
        NativeOp.apply_ => $ {
            var inscope xs <- args |> skip(1) |> take(length(args) - 2)
            var inscope tail <- items(vm, back(args), true)
            push(xs, tail)
            return apply(vm, a, xs)
        }
        NativeOp.map_ => $ {
            var inscope xs <- items(vm, b, true)
            var inscope result : array<Val>
            for (x in xs) {
                let value = apply(vm, a, [x])
                push(result, value)
                push(vm.root_values, value)
                if (vm.thrown >= 0) return NIL
            }
            return list(vm, result)
        }
        NativeOp.throw_ => $ { vm.thrown = a; return NIL }
        NativeOp.atom_ => $ { return alloc(vm, Data(atom = a)) }
        NativeOp.deref_ | NativeOp.reset | NativeOp.swap => $ {
            if (!(vm.values[a].data is atom)) return fail(vm, "{name}: expected an atom")
            if (op == NativeOp.deref_) return vm.values[a].data as atom
            var value = b
            if (op == NativeOp.swap) {
                var inscope xs <- args |> skip(2)
                push(xs, vm.values[a].data as atom, 0)
                value = apply(vm, b, xs)
            }
            if (vm.thrown >= 0) return NIL
            (vm.values[a].data as atom) = value
            return value
        }
        NativeOp.meta => $ { return vm.values[a].meta }
        NativeOp.with_meta => $ {
            if (!sequential(vm, a) && !(vm.values[a].data is map_) && !callable(vm, a)) return fail(vm, "with-meta: unsupported value")
            let result = copy_value(vm, a)
            vm.values[result].meta = b
            return result
        }
        NativeOp.time_ms => $ { return number(vm, vm.clock_epoch + get_time_nsec(vm.clock_start) / 1000000l) }
    }
    return NIL
}

def rep(var vm : VM; source : string) : Val {
    var inscope forms <- read_all(vm, source)
    let value_mark = length(vm.root_values)
    push(vm.root_values, forms)
    defer() { resize(vm.root_values, value_mark) }
    var result = NIL
    for (form in forms) {
        if (vm.thrown >= 0) return NIL
        result = eval(vm, form)
    }
    return result
}

def init_core(var vm : VM) {
    vm.clock_epoch = int64(get_clock()) * 1000l
    vm.clock_start = ref_time_ticks()
    var inscope natives <- [
        ("+", NativeOp.add),
        ("-", NativeOp.subtract),
        ("*", NativeOp.multiply),
        ("/", NativeOp.divide),
        ("<", NativeOp.less),
        ("<=", NativeOp.less_equal),
        (">", NativeOp.greater),
        (">=", NativeOp.greater_equal),
        ("=", NativeOp.equal_),
        ("list", NativeOp.list_),
        ("list?", NativeOp.is_list),
        ("vector", NativeOp.vector_),
        ("vector?", NativeOp.is_vector),
        ("hash-map", NativeOp.hash_map),
        ("map?", NativeOp.is_map),
        ("empty?", NativeOp.is_empty),
        ("assoc", NativeOp.assoc),
        ("dissoc", NativeOp.dissoc),
        ("get", NativeOp.get_),
        ("contains?", NativeOp.contains),
        ("keys", NativeOp.keys_),
        ("vals", NativeOp.vals),
        ("pr-str", NativeOp.pr_str),
        ("str", NativeOp.str_),
        ("prn", NativeOp.prn),
        ("println", NativeOp.println),
        ("read-string", NativeOp.read_string),
        ("readline", NativeOp.readline),
        ("slurp", NativeOp.slurp),
        ("sequential?", NativeOp.is_sequential),
        ("cons", NativeOp.cons),
        ("concat", NativeOp.concat),
        ("vec", NativeOp.vec),
        ("count", NativeOp.count_),
        ("nth", NativeOp.nth),
        ("first", NativeOp.first_),
        ("rest", NativeOp.rest),
        ("apply", NativeOp.apply_),
        ("map", NativeOp.map_),
        ("conj", NativeOp.conj),
        ("seq", NativeOp.seq),
        ("throw", NativeOp.throw_),
        ("nil?", NativeOp.is_nil),
        ("true?", NativeOp.is_true),
        ("false?", NativeOp.is_false),
        ("string?", NativeOp.is_string),
        ("symbol", NativeOp.symbol_),
        ("symbol?", NativeOp.is_symbol),
        ("keyword", NativeOp.keyword_),
        ("keyword?", NativeOp.is_keyword),
        ("number?", NativeOp.is_number),
        ("fn?", NativeOp.is_fn),
        ("macro?", NativeOp.is_macro),
        ("with-meta", NativeOp.with_meta),
        ("meta", NativeOp.meta),
        ("atom", NativeOp.atom_),
        ("atom?", NativeOp.is_atom),
        ("deref", NativeOp.deref_),
        ("reset!", NativeOp.reset),
        ("swap!", NativeOp.swap),
        ("time-ms", NativeOp.time_ms),
        ("eval", NativeOp.eval_)
    ]
    for ((name, op) in natives) {
        let value = alloc(vm, Data(native = NativeFn(op = op, name = name, arity = native_arity(op))))
        set_binding(vm, 0, name, value)
    }
    set_binding(vm, 0, "*host-language*", text(vm, "daScript"))
    set_binding(vm, 0, "*ARGV*", list(vm, array<Val>()))
    rep(vm, "(def! not (fn* (a) (if a false true)))")
    rep(vm, "(def! load-file (fn* (f) (eval (read-string (str \"(do \" (slurp f) \"\nnil)\")))))")
    rep(vm, "(defmacro! cond (fn* (& xs) (if (> (count xs) 0) (list 'if (first xs) (if (> (count xs) 1) (nth xs 1) (throw \"odd number of forms to cond\")) (cons 'cond (rest (rest xs)))))))")
}
