options gen2
module types

require daslib/match public
require daslib/linq public
require daslib/strings_boost public

// Values and environments use stable arena indices. This permits recursive
// closures and cyclic atoms without reference-counting cycles or unsafe pointers.
typedef Val = int

struct Closure {
    params : Val
    body : Val
    env : int
    macro_ : bool
    fixed_arity : int
    has_rest : bool
    rest_symbol : Val
}

enum NativeOp {
    add
    subtract
    multiply
    divide
    less
    less_equal
    greater
    greater_equal
    equal_
    list_
    is_list
    vector_
    is_vector
    hash_map
    is_map
    is_empty
    assoc
    dissoc
    get_
    contains
    keys_
    vals
    pr_str
    str_
    prn
    println
    read_string
    readline
    slurp
    is_sequential
    cons
    concat
    vec
    count_
    nth
    first_
    rest
    apply_
    map_
    conj
    seq
    throw_
    is_nil
    is_true
    is_false
    is_string
    symbol_
    is_symbol
    keyword_
    is_keyword
    is_number
    is_fn
    is_macro
    with_meta
    meta
    atom_
    is_atom
    deref_
    reset
    swap
    time_ms
    eval_
}

struct NativeFn {
    op : NativeOp
    name : string
    arity : int2
}

// A list tail is a flat suffix view over an immutable list/vector cell.
// owner always names the original owning sequence, never another tail.
struct ListTail {
    owner : Val
    start : int
}

struct SequenceView {
    owner : Val = -1
    start : int
    count : int
}

variant Data {
    nil_
    boolean : bool
    number : int64
    symbol : string
    text : string
    keyword : string
    list : array<Val>
    list_tail : ListTail
    vector : array<Val>
    map_ : table<string; Val>
    native : NativeFn
    function_ : Closure
    atom : Val
}

struct Cell {
    data : Data
    meta : Val
    marked : bool
    live : bool = true
}

struct Env {
    bindings : table<Val; Val>
    outer : int = -1
    marked : bool
    live : bool = true
}

struct EvalBuffers {
    expressions : array<Val>
    arguments : array<Val>
}

struct VM {
    values : array<Cell>
    envs : array<Env>
    free_values : array<int>
    free_envs : array<int>
    thrown : Val = -1
    clock_epoch : int64
    clock_start : int64
    // Explicit interpreter roots allow collection between evaluator iterations.
    root_values : array<Val>
    root_envs : array<int>
    allocations_since_gc : int
    gc_min_interval : int = 16384
    gc_threshold : int = 16384
    collections : int
    debug_possible : bool
    // Heap-stable frame buffers can be reused without borrowing arena cells
    // across recursive evaluation or allocating new arrays for each call.
    eval_buffers : array<EvalBuffers?>
    // Weak interning: the collector removes names whose symbol cells die.
    symbols : table<string; Val>
    debug_symbol : Val
}

def evaluation_buffers(var vm : VM; depth : int) : EvalBuffers? {
    while (length(vm.eval_buffers) <= depth) {
        push(vm.eval_buffers, new EvalBuffers())
    }
    return vm.eval_buffers[depth]
}

let NIL = 0
let FALSE = 1
let TRUE = 2

def boolean(b : bool) : Val => b ? TRUE : FALSE
def truthy(v : Val) : bool => v != NIL && v != FALSE

def alloc(var vm : VM; var data : Data implicit) : Val {
    vm.allocations_since_gc++
    var cell = Cell(data <- data)
    if (!empty(vm.free_values)) {
        let id = back(vm.free_values)
        pop(vm.free_values)
        vm.values[id] <- cell
        return id
    }
    let id = length(vm.values)
    emplace(vm.values, cell)
    return id
}

def number(var vm : VM; n : int64) : Val => alloc(vm, Data(number = n))
def text(var vm : VM; s : string) : Val => alloc(vm, Data(text = s))
def symbol(var vm : VM; s : string) : Val {
    let found = vm.symbols?[s] ?? -1
    if (found >= 0) return found
    let value = alloc(vm, Data(symbol = s))
    vm.symbols[s] = value
    return value
}
def keyword(var vm : VM; s : string) : Val => alloc(vm, Data(keyword = s))
def list(var vm : VM; var xs : array<Val> implicit) : Val => alloc(vm, Data(list <- xs))
def vector(var vm : VM; var xs : array<Val> implicit) : Val => alloc(vm, Data(vector <- xs))

def fail(var vm : VM; message : string) : Val {
    if (vm.thrown < 0) { vm.thrown = text(vm, message) }
    return NIL
}

def new_env(var vm : VM; outer : int = -1) : int {
    vm.allocations_since_gc++
    var env = Env(outer = outer)
    if (!empty(vm.free_envs)) {
        let id = back(vm.free_envs)
        pop(vm.free_envs)
        vm.envs[id] <- env
        return id
    }
    let id = length(vm.envs)
    emplace(vm.envs, env)
    return id
}

def lookup_symbol(vm : VM; env : int; name : Val) : Val {
    var e = env
    while (e >= 0) {
        let value = vm.envs[e].bindings?[name] ?? -1
        if (value >= 0) return value
        e = vm.envs[e].outer
    }
    return -1
}

def lookup(vm : VM; env : int; name : string) : Val {
    let key = vm.symbols?[name] ?? -1
    return key < 0 ? -1 : lookup_symbol(vm, env, key)
}

def set_symbol_binding(var vm : VM; env : int; name : Val; value : Val) : Val {
    vm.envs[env].bindings[name] = value
    // Once seen, keep the slow debug lookup path enabled conservatively.
    if (name == vm.debug_symbol) { vm.debug_possible = true }
    return value
}

def set_binding(var vm : VM; env : int; name : string; value : Val) : Val {
    let key = symbol(vm, name)
    return set_symbol_binding(vm, env, key, value)
}

def list_like(vm : VM; v : Val) : bool => vm.values[v].data is list || vm.values[v].data is list_tail

def sequential(vm : VM; v : Val) : bool => list_like(vm, v) || vm.values[v].data is vector

def sequence_view(vm : VM; v : Val) : SequenceView {
    match (vm.values[v].data) {
        Data(list = xs) | Data(vector = xs) => $ {
            return SequenceView(owner = v, count = length(xs))
        }
        Data(list_tail = tail) => $ {
            match (vm.values[tail.owner].data) {
                Data(list = xs) | Data(vector = xs) => $ {
                    return SequenceView(owner = tail.owner, start = tail.start, count = length(xs) - tail.start)
                }
                _ => $ {}
            }
        }
        _ => $ {}
    }
    return SequenceView()
}

// Callers validate the logical index. The owner's array supplies the physical
// bounds check; no reference into vm.values survives this read-only helper.
def sequence_at(vm : VM; view : SequenceView; index : int) : Val {
    match (vm.values[view.owner].data) {
        Data(list = xs) | Data(vector = xs) => $ { return xs[view.start + index] }
        _ => $ { return NIL }
    }
    return NIL
}

def copy_items(var vm : VM; v : Val; var result : array<Val>; nil_ok : bool = false) {
    match (vm.values[v].data) {
        Data(list = xs) | Data(vector = xs) => $ { result := xs }
        Data(list_tail = _) => $ {
            let view = sequence_view(vm, v)
            match (vm.values[view.owner].data) {
                Data(list = xs) | Data(vector = xs) => $ {
                    // xs owns immutable storage; result is a separate buffer.
                    // Check the complete source interval before taking pointers.
                    if (view.start < 0 || view.start > length(xs) || view.count < 0 || view.count > length(xs) - view.start) {
                        panic("copy_items: invalid sequence interval")
                    }
                    unsafe {
                        if (addr(xs) == addr(result)) { panic("copy_items: destination aliases sequence owner") }
                    }
                    resize(result, view.count)
                    if (view.count != 0) {
                        // Val is an integer handle (POD). No arena mutation, GC,
                        // resize or callback occurs while these pointers exist.
                        // Use a wide byte count to avoid int multiplication overflow.
                        unsafe { memcpy(addr(result[0]), addr(xs[view.start]), int64(view.count) * int64(typeinfo sizeof(type<Val>))) }
                    }
                }
                _ => $ { resize(result, 0) }
            }
        }
        Data(nil_) && nil_ok => $ { resize(result, 0) }
        _ => $ { resize(result, 0); fail(vm, "expected a list or vector") }
    }
}

def items(var vm : VM; v : Val; nil_ok : bool = false) : array<Val> {
    var result : array<Val>
    copy_items(vm, v, result, nil_ok)
    return <- result
}

def rest_list(var vm : VM; v : Val) : Val {
    if (v == NIL) return list(vm, array<Val>())
    let view = sequence_view(vm, v)
    if (view.owner < 0) return fail(vm, "expected a list or vector")
    if (view.count <= 1) return list(vm, array<Val>())
    // Copy only two integers. Allocation may relocate the arena, so the view
    // is detached before allocating. Metadata of the result starts at nil.
    return alloc(vm, Data(list_tail = ListTail(owner = view.owner, start = view.start + 1)))
}

// An empty symbol name is valid; absence must have its own tag.
def symbol_name(vm : VM; v : Val) : Option<string> {
    return match (vm.values[v].data) {
        Data(symbol = name) => some(name)
        _ => none(type<string>)
    }
}

def symbol_matches(vm : VM; v : Val; name : string) : bool {
    return match (vm.values[v].data) {
        Data(symbol = actual) => actual == name
        _ => false
    }
}

def require_symbol(var vm : VM; v : Val; context : string) : string {
    match (symbol_name(vm, v)) {
        some(name) => $ { return name }
        none() => $ { fail(vm, "{context}: expected a symbol"); return "" }
    }
    return ""
}

// A tagged key keeps strings and keywords distinct, including empty strings.
def map_key(var vm : VM; v : Val) : string {
    match (vm.values[v].data) {
        Data(text = s) => $ { return "s{s}" }
        Data(keyword = s) => $ { return "k{s}" }
        _ => $ { fail(vm, "map key must be a string or keyword"); return "" }
    }
    return ""
}

def make_map(var vm : VM; xs : array<Val>) : Val {
    if (length(xs) % 2 != 0) return fail(vm, "hash-map requires key/value pairs")
    var result : table<string; Val>
    for (pair in range(length(xs) / 2)) {
        let i = pair * 2
        let k = map_key(vm, xs[i])
        if (vm.thrown >= 0) return NIL
        result[k] = xs[i + 1]
    }
    return alloc(vm, Data(map_ <- result))
}

def init_vm() : VM {
    var vm = VM()
    alloc(vm, Data(nil_))
    alloc(vm, Data(boolean = false))
    alloc(vm, Data(boolean = true))
    vm.debug_symbol = symbol(vm, "DEBUG-EVAL")
    new_env(vm)
    return <- vm
}
