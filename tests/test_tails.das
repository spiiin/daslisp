options gen2
options persistent_heap
options gc
options stack = 16777216
require ../runtime.das

var checked = 0

def check(var vm : VM; source, expected : string) {
    let value = rep(vm, source)
    if (vm.thrown >= 0) {
        print("UNEXPECTED ERROR: {source}: {pr_str(vm, vm.thrown, false)}\n")
        verify(false)
    }
    let actual = pr_str(vm, value)
    if (actual != expected) {
        print("FAIL {source}\nexpected {expected}\ngot {actual}\n")
        verify(false)
    }
    checked++
    collect(vm)
}

def rejects(var vm : VM; source : string) {
    rep(vm, source)
    verify(vm.thrown >= 0)
    vm.thrown = -1
    checked++
    collect(vm)
}

// SDK heap_collect walks interpreter frames; evaluation kernels may be JIT.
[export, no_jit]
def main() {
    var vm <- init_vm()
    init_core(vm)
    vm.gc_min_interval = 32
    vm.gc_threshold = 32
    check(vm, "(rest '(1 2 3 4))", "(2 3 4)")
    check(vm, "(rest [1 2 3])", "(2 3)")
    check(vm, "(rest (rest [1 2 3 4]))", "(3 4)")
    check(vm, "(list (list? (rest [1 2])) (vector? (rest [1 2])) (sequential? (rest [1 2])))", "(true false true)")
    check(vm, "(list (rest nil) (rest []) (rest ()) (rest [1]) (rest (rest [1 2])))", "(() () () () ())")
    check(vm, "(let* [xs (rest [0 1 2 3])] (list (count xs) (empty? xs) (first xs) (nth xs 2)))", "(3 false 1 3)")
    check(vm, "(= (rest [0 1 [2]]) '(1 (2)))", "true")
    check(vm, "(= '(1 (2)) (rest [0 1 [2]]))", "true")
    check(vm, "(= (rest [0 1 2]) (rest '(9 1 2)))", "true")
    check(vm, "(= (rest [0 1 2]) (rest '(9 1 3)))", "false")
    check(vm, "(= (rest [0 1 2]) [1])", "false")
    check(vm, "(list (= (rest [0 1]) 1) (= 1 (rest [0 1])))", "(false false)")
    check(vm, "(vec (rest [0 1 2]))", "[1 2]")
    check(vm, "(seq (rest [0 1 2]))", "(1 2)")
    check(vm, "(cons 9 (rest [0 1 2]))", "(9 1 2)")
    check(vm, "(concat (rest [0 1 2]) (rest [0 3 4]))", "(1 2 3 4)")
    check(vm, "(conj (rest [0 1 2]) 8 9)", "(9 8 1 2)")
    check(vm, "(apply + 7 (rest [0 1 2 3]))", "13")
    check(vm, "(map (fn* [x] (+ x 1)) (rest [0 1 2 3]))", "(2 3 4)")
    check(vm, "(eval (rest '(ignore + 1 2)))", "3")
    check(vm, "(eval (rest '(ignore if true 4 5)))", "4")
    check(vm, "(eval (list 'fn* (rest '[ignore x]) 'x))", "#<function>")
    check(vm, "((eval (list 'fn* (rest '[ignore x & xs]) '(list x xs))) 1 2 3)", "(1 (2 3))")
    check(vm, "(eval (list 'let* (rest '[ignore x 4 y 5]) '(+ x y)))", "9")
    check(vm, "(eval (list 'try* '(throw 8) (rest '(ignore catch* e e))))", "8")
    check(vm, "(eval (list 'quasiquote (rest '(ignore 1 (unquote (+ 1 1))))))", "(1 2)")
    check(vm, "(eval (list 'quasiquote (list (rest '(ignore splice-unquote (list 2 3))))))", "(2 3)")
    check(vm, "(eval (list 'macroexpand (rest '(ignore cond true 7))))", "(if true 7 (cond))")
    check(vm, "(pr-str (rest [0 \"a\\n\" :b]))", "\"(\\\"a\\\\n\\\" :b)\"")
    check(vm, "(str (rest [0 \"ab\" :b]))", "\"(ab :b)\"")
    check(vm, "(do (def! original (with-meta [1 2 3 4] \{:old 1\})) (def! tail (rest original)) (list original tail (meta tail)))", "([1 2 3 4] (2 3 4) nil)")
    check(vm, "(do (def! tagged (with-meta tail \{:new 2\})) (list (meta tail) (get (meta tagged) :new) (meta (rest tagged))))", "(nil 2 nil)")
    check(vm, "(do (cons 0 tail) (conj tail 9) (vec tail) (list original tail tagged))", "([1 2 3 4] (2 3 4) (2 3 4))")
    check(vm, "(= tagged tail)", "true")
    // Keep only the tail in the environment: the original owner and its
    // elements must remain live through arena and SDK heap collection.
    check(vm, "(def! original nil)", "nil")
    unsafe { heap_collect(true, true) }
    check(vm, "(list (first tail) (count tail) (nth tagged 2))", "(2 3 4)")
    check(vm, "(def! churn (fn* [n] (if (= n 0) nil (churn (- n 1)))))", "#<function>")
    check(vm, "(let* [xs (rest [(let* [x 1] (fn* [] x)) (let* [x 7] (fn* [] x))])] (do (churn 500) ((first xs))))", "7")
    check(vm, "(do (def! a (atom nil)) (reset! a (rest [0 a])) (atom? (first @a)))", "true")
    check(vm, "(atom? (first @a))", "true")
    rejects(vm, "(rest 1)")
    rejects(vm, "(nth (rest [0 1]) -1)")
    rejects(vm, "(nth (rest [0 1]) 1)")
    rejects(vm, "((eval (list 'fn* (rest '[ignore x]) 'x)))")
    // Structural check: advancing a view allocates just a cell, retaining
    // one owner. with-meta shares storage while keeping independent metadata.
    let owner = list(vm, [number(vm, 1l), number(vm, 2l), number(vm, 3l), number(vm, 4l)])
    let one = rest_list(vm, owner)
    let two = rest_list(vm, one)
    let tagged_copy = copy_value(vm, two)
    verify(vm.values[one].data is list_tail && vm.values[two].data is list_tail)
    verify((vm.values[one].data as list_tail).owner == owner)
    verify((vm.values[two].data as list_tail).owner == owner)
    verify((vm.values[two].data as list_tail).start == 2)
    verify((vm.values[tagged_copy].data as list_tail).owner == owner)
    collect(vm, [two])
    verify(vm.values[owner].live && !vm.values[one].live)
    verify(pr_str(vm, two) == "(3 4)")
    collect(vm)
    verify(!vm.values[owner].live && !vm.values[two].live)
    checked++
    // Repeated rest must stay flat and avoid a deep graph of tail objects.
    var inscope values : array<Val>
    for (i in range(2000)) { push(values, number(vm, int64(i))) }
    let long_owner = vector(vm, values)
    var current = long_owner
    for (i in range(1, 1999)) {
        current = rest_list(vm, current)
        if (i % 50 == 0) { collect(vm, [current]) }
        verify((vm.values[current].data as list_tail).owner == long_owner)
        verify((vm.values[current].data as list_tail).start == i)
        verify(numeric(vm, first_item(vm, current)) == int64(i))
    }
    collect(vm, [current])
    verify(collection_size(vm, current) == 2)
    checked++
    print("PASS: {checked} tail checks (sharing, immutability, evaluation, metadata and GC)\n")
}
