options gen2
options persistent_heap
options gc
require ../runtime.das

var checked = 0

def check(var vm : VM; source, expected : string) {
    let value = rep(vm, source)
    verify(vm.thrown < 0)
    verify(pr_str(vm, value) == expected)
    checked++
    collect(vm)
}

[export]
def main() {
    var vm <- init_vm()
    init_core(vm)
    vm.gc_min_interval = 32
    vm.gc_threshold = 32
    check(vm, "(def! churn (fn* [n] (if (= n 0) nil (churn (- n 1)))))", "#<function>")
    check(vm, "(do (apply + [1 2]) (churn 500) (+ 40 2))", "42")
    check(vm, "(do (map list [1 2 3]) (churn 500) (+ 40 2))", "42")
    check(vm, "(let* [a (atom \{\})] (do (swap! a assoc :x 7) (churn 500) (get @a :x)))", "7")
    check(vm, "(let* [x 41] (do (apply list [1 2]) (churn 500) (+ x 1)))", "42")
    check(vm, "(do (apply + []) (churn 500) (def! after-native 17) after-native)", "17")
    check(vm, "(do (try* (apply nth [[1] 5]) (catch* e nil)) (churn 500) 29)", "29")
    let held = text(vm, "caller root")
    let plus = lookup(vm, 0, "+")
    let first = lookup(vm, 0, "first")
    with_roots(vm, [held]) $() : Val {
        let mark = length(vm.root_values)
        let result = apply(vm, plus, [number(vm, 1l), number(vm, 2l)])
        verify(numeric(vm, result) == 3l)
        verify(length(vm.root_values) == mark && back(vm.root_values) == held)
        collect(vm)
        verify(vm.values[held].live && pr_str(vm, held, false) == "caller root")
        checked++
        apply(vm, first, array<Val>())
        verify(vm.thrown >= 0)
        vm.thrown = -1
        verify(length(vm.root_values) == mark && back(vm.root_values) == held)
        checked++
        return held
    }
    verify(empty(vm.root_values) && empty(vm.root_envs))
    print("PASS: {checked} apply-root checks (native fast path, errors, caller roots and GC)\n")
}
