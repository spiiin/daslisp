options gen2
options stack = 16777216
options persistent_heap
options gc
require ../runtime.das
require ../memory.das

var checked = 0

def check(var vm : VM; source, expected : string) {
    let result = rep(vm, source)
    if (vm.thrown >= 0) {
        print("UNEXPECTED ERROR in {source}: {pr_str(vm, vm.thrown, false)}\n")
        verify(false)
    }
    let actual = pr_str(vm, result)
    if (actual != expected) {
        print("FAIL {source}\n  expected {expected}\n  got      {actual}\n")
        verify(false)
    }
    checked++
    collect(vm)
}

def rejects(var vm : VM; source : string) {
    rep(vm, source)
    if (vm.thrown < 0) { print("SHOULD REJECT: {source}\n"); verify(false) }
    vm.thrown = -1
    checked++
    collect(vm)
}

// SDK heap_collect walks interpreter frames; evaluation kernels may be JIT.
[export, no_jit]
def main() {
    var vm <- init_vm()
    init_core(vm)
    check(vm, "(+ 1 (* 2 3))", "7")
    check(vm, "(do (def! odd@name~with^symbols 5) odd@name~with^symbols)", "5")
    check(vm, "(- -2)", "2")
    check(vm, "(/ -7 2)", "-3")
    check(vm, "(let* [x 2 y (+ x 3)] (* x y))", "10")
    check(vm, "(do (def! x 7) (def! make-adder (fn* (x) (fn* (y) (+ x y)))) (def! add2 (make-adder 2)) (add2 10))", "12")
    check(vm, "(add2 x)", "9")
    check(vm, "((fn* (x & rest) rest) 1 2 3)", "(2 3)")
    check(vm, "((fn* [& rest] rest))", "()")
    check(vm, "(apply + 1 2 [3 4])", "10")
    check(vm, "(map add2 [1 2 3])", "(3 4 5)")
    check(vm, "(do (def! f (fn* [x] (number? x))) (defmacro! m f) (list (f (+ 1 1)) (m (+ 1 1))))", "(true false)")
    check(vm, "(cond false 1 true 2)", "2")
    check(vm, "(let* [xs '(2 3)] `[1 ~@xs ~(+ 2 2)])", "[1 2 3 4]")
    check(vm, "(= '(1 [2]) [1 '(2)])", "true")
    check(vm, "(= [1 [2 3]] '(1 (2 4)))", "false")
    check(vm, "(= [1 2] '(1))", "false")
    check(vm, "(= [] ())", "true")
    check(vm, "(= [\{:x [1 2]\}] '(\{:x (1 2)\}))", "true")
    check(vm, "(list (count '(1 2 3)) (count [4 5]) (count nil) (count \"abc\") (count \{:x 1\}))", "(3 2 0 3 1)")
    check(vm, "(list (empty? []) (empty? ()) (empty? nil) (empty? [nil]))", "(true true true false)")
    check(vm, "(list (first [7 8]) (first '(9)) (first []) (first nil))", "(7 9 nil nil)")
    check(vm, "(list (nth '(1 2 3) 2) (nth [4 5] 0))", "(3 4)")
    check(vm, "(get (assoc \{\"x\" 1 :x 2\} :x 3) \"x\")", "1")
    check(vm, "(do (def! original [1 2 3]) (def! tagged (with-meta original \{:x 1\})) (list original tagged (meta original) (get (meta tagged) :x)))", "([1 2 3] [1 2 3] nil 1)")
    check(vm, "(get (meta tagged) :x)", "1")
    check(vm, "(do (def! original-map \{:x 1\}) (def! tagged-map (with-meta original-map 9)) (get (assoc tagged-map :x 2) :x))", "2")
    check(vm, "(get original-map :x)", "1")
    check(vm, "(do (def! tagged-native (with-meta + \{:x 8\})) (list (tagged-native 1 2) (meta +) (get (meta tagged-native) :x)))", "(3 nil 8)")
    check(vm, "(do (def! tagged-closure (with-meta add2 \{:x 9\})) (list (tagged-closure 4) (meta add2) (get (meta tagged-closure) :x)))", "(6 nil 9)")
    check(vm, "(do (def! counter (atom 0)) (try* (swap! counter (fn* (x) (throw :oops))) (catch* e e)))", ":oops")
    check(vm, "@counter", "0")
    check(vm, "(try* (throw \{:error [1 2]\}) (catch* e (get e :error)))", "[1 2]")
    check(vm, "(try* (try* (throw 1) (catch* e (throw 2))) (catch* e e))", "2")
    check(vm, "(try* (do (throw 1) (reset! counter 9)) (catch* e @counter))", "0")
    check(vm, "(try* (+ (throw 1) (reset! counter 9)) (catch* e @counter))", "0")
    check(vm, "(do (def! global 42) (let* [global 0] (eval 'global)))", "42")
    // Repeated copying forces arena growth. Borrowed match payloads must not
    // be used after allocating into vm.values, and copies must own containers.
    let sources <- read_all(vm, "[1 [2 3]] (4 5) \{:x [6 7]\}")
    for (round in range(256)) {
        for (source in sources) {
            let copied = copy_value(vm, source)
            verify(vm.thrown < 0 && equal(vm, source, copied))
        }
    }
    checked++
    collect(vm)
    check(vm, "(do (def! loop (fn* [n acc] (if (= n 0) acc (let* [next (- n 1)] (do nil (loop next (+ acc n))))))) (loop 100000 0))", "5000050000")
    // A closure's environment can point back to the same closure.
    check(vm, "(do (def! recursive (let* [local (fn* [n] (if (= n 0) 7 (local (- n 1))))] local)) (recursive 4))", "7")
    check(vm, "(recursive 10)", "7")
    // Retain a cyclic atom; then make it unreachable and ensure it is reclaimed.
    check(vm, "(do (def! cycle (atom nil)) (reset! cycle cycle) (atom? @cycle))", "true")
    check(vm, "(atom? @cycle)", "true")
    let cycle = lookup(vm, 0, "cycle")
    check(vm, "(def! cycle nil)", "nil")
    verify(!vm.values[cycle].live)
    check(vm, "9223372036854775807", "9223372036854775807")
    check(vm, "-9223372036854775808", "-9223372036854775808")
    check(vm, "(str \"a\\n\" \"b\")", "\"a\\nb\"")
    check(vm, "; a comment\n(+ 1, 2) ; trailing\n(+ 3 4)", "7")
    // MAL's ASCII whitespace includes form feed and vertical tab. daScript
    // has no \v character escape, so construct that byte with a string writer.
    let vt = build_string() $(var writer) { write_char(writer, 11) }
    check(vm, "\f(+ 1\f2)\f", "3")
    check(vm, "{vt}(+ 1{vt}2){vt}", "3")
    check(vm, "[1\f2{vt}3]", "[1 2 3]")
    check(vm, "(let* [x{vt}4] x)", "4")
    // Empty symbol names must survive every binding path and macro lookup.
    check(vm, "(do (eval (list 'def! (symbol \"\") 7)) (eval (symbol \"\")))", "7")
    check(vm, "(eval (list 'let* (vector (symbol \"\") 41) (symbol \"\")))", "41")
    check(vm, "((eval (list 'fn* (vector (symbol \"\")) (symbol \"\"))) 9)", "9")
    check(vm, "((eval (list 'fn* (vector '& (symbol \"\")) (symbol \"\"))) 1 2)", "(1 2)")
    check(vm, "(eval (list 'try* (list 'throw 5) (list 'catch* (symbol \"\") (symbol \"\"))))", "5")
    check(vm, "(do (eval (list 'defmacro! (symbol \"\") (list 'fn* [] 42))) (eval (list (symbol \"\"))))", "42")
    check(vm, "(eval (list 'macroexpand (list (symbol \"\"))))", "42")
    check(vm, "(eval (list 'macroexpand (list 0)))", "(0)")
    rejects(vm, "(eval (list 'fn* (vector (symbol \"\") (symbol \"\")) 1))")
    rejects(vm, "(eval (list 'let* [0 1] 2))")
    rejects(vm, "(nth [1] \"0\")")
    rejects(vm, "(empty? 3)")
    for (source in ["(", "[1 2)", "\"unterminated", "'", "\{:a\}", "\{1 2\}", "9223372036854775808", "-9223372036854775809", "missing", "(1 2)", "(if true)", "(def! 1 2)", "(let* [x] x)", "(let* [1 2] 3)", "(fn* [x x] x)", "(fn* [&] nil)", "(fn* [& x y] nil)", "((fn* [x] x))", "((fn* [] 1) 2)", "(nth [1] -1)", "(nth [1] 1)", "(+ 1 \"x\")", "(/ 1 0)", "(/ -9223372036854775808 -1)", "(first 1)", "(reset! 1 2)", "(assoc \{\} :a)", "(try* 1 (bad e e))", "(slurp \"__daslisp_missing_file__\")"]) {
        rejects(vm, source)
    }
    // Slot reuse stays bounded over many read/eval/collect rounds.
    let before_values = length(vm.values)
    let before_envs = length(vm.envs)
    for (i in range(100)) { check(vm, "(add2 5)", "7") }
    verify(length(vm.values) <= before_values + 32)
    verify(length(vm.envs) <= before_envs + 2)
    // Force collection inside a single evaluation, including a child tail
    // call that temporarily leaves the caller's let* environment.
    var stress <- init_vm()
    init_core(stress)
    stress.gc_min_interval = 32
    stress.gc_threshold = 32
    check(stress, "(def! churn (fn* [n] (if (= n 0) nil (churn (- n 1)))))", "#<function>")
    let before_collections = stress.collections
    check(stress, "(let* [start 41 _ (churn 500)] (+ start 1))", "42")
    verify(stress.collections > before_collections + 1)
    check(stress, "(let* [fs (list (let* [x 7] (fn* [] x)) (do (churn 500) (fn* [] 8)))] ((first fs)))", "7")
    check(stress, "(let* [fs [(let* [x 7] (fn* [] x)) (do (churn 500) (fn* [] 8))]] ((first fs)))", "7")
    check(stress, "(let* [m \{:a (let* [x 7] (fn* [] x)) :b (do (churn 500) (let* [x 8] (fn* [] x)))\}] (+ ((get m :a)) ((get m :b))))", "15")
    check(stress, "(let* [fs (map (fn* [x] (do (churn 300) (fn* [] x))) [1 2 3])] (map (fn* [f] (f)) fs))", "(1 2 3)")
    check(stress, "(try* (do (churn 500) (throw [7])) (catch* e (first e)))", "7")
    check(stress, "(let* [a (atom (list 7))] (do (swap! a (fn* [old] (do (reset! a nil) (churn 500) old))) @a))", "(7)")
    check(stress, "(defmacro! finish (fn* [x] (do (churn 500) (list 'quote x))))", "#<macro>")
    check(stress, "(defmacro! begin (fn* [] (list 'finish (list 7 8))))", "#<macro>")
    check(stress, "(macroexpand (begin))", "(quote (7 8))")
    check(stress, "(churn 500)\n(def! after-gc 6)\nafter-gc", "6")
    rejects(stress, "(do (churn 500) (throw \"expected\"))")
    verify(empty(stress.root_values) && empty(stress.root_envs))
    check(stress, "(churn 20000)", "nil")
    verify(length(stress.values) < 5000 && length(stress.envs) < 5000)
    // Rest signatures and parameter names are prepared once, including empty
    // names and the debug binding that must enable the tracing slow path.
    check(stress, "((fn* [x & xs] (list x xs)) 1 2 3)", "(1 (2 3))")
    rejects(stress, "((fn* [x & xs] x))")
    check(stress, "((fn* [DEBUG-EVAL] DEBUG-EVAL) false)", "false")
    verify(stress.debug_possible)
    // Interned symbol identities are weak: a live environment keeps its key,
    // while unreferenced generated names disappear at collection.
    let same_a = symbol(stress, "a-temporary-symbol")
    let same_b = symbol(stress, "a-temporary-symbol")
    verify(same_a == same_b)
    collect(stress)
    verify(!key_exists(stress.symbols, "a-temporary-symbol"))
    let rebound = symbol(stress, "a-temporary-symbol")
    let bound_value = number(stress, 17l)
    set_symbol_binding(stress, 0, rebound, bound_value)
    collect(stress)
    verify(lookup(stress, 0, "a-temporary-symbol") == bound_value)
    check(stress, "a-temporary-symbol", "17")
    checked++
    let held = list(stress, [number(stress, 23l)])
    let pinned = with_roots(stress, [held]) $() : Val {
        rep(stress, "(churn 500)")
        return first_item(stress, held)
    }
    verify(numeric(stress, pinned) == 23l && empty(stress.root_values))
    checked++
    unsafe { heap_collect(true, true) }
    print("PASS: {checked} checks (including GC, errors and 100000 tail calls)\n")
}
