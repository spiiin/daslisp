options gen2
options persistent_heap
options gc
options stack = 16777216
require ../runtime.das
require daslib/clargs
require daslib/fio

[export]
def main() : int {
    var vm <- init_vm()
    init_core(vm)
    var inscope args <- get_user_args()
    if (length(args) != 1) { print("Usage: size\n"); return 1 }
    let size = int(args[0])
    if (size < 1) { print("Size must be positive\n"); return 1 }
    var inscope values : array<Val>
    reserve(values, size)
    for (i in range(size)) { push(values, number(vm, int64(i))) }
    let input = list(vm, values)
    set_binding(vm, 0, "input", input)
    rep(vm, "(def! walk (fn* [xs n] (if (empty? xs) n (walk (rest xs) (+ n 1)))))")
    let ast = read_str(vm, "(walk input 0)")
    let before_gc = vm.collections
    let start = ref_time_ticks()
    let result = eval(vm, ast)
    let elapsed = get_time_nsec(start)
    if (vm.thrown >= 0) { print("Error: {pr_str(vm, vm.thrown)}\n"); return 1 }
    if (numeric(vm, result) != int64(size)) { print("Error: incorrect result\n"); return 1 }
    print("TAIL size={size} elapsed_ns={elapsed} values={length(vm.values)} envs={length(vm.envs)} collections={vm.collections - before_gc} result={size}\n")
    return 0
}
