options gen2
options persistent_heap
options gc
require ../runtime.das
require daslib/clargs
require daslib/fio

[export]
def main() : int {
    var inscope args <- get_user_args()
    if (length(args) != 3) { print("Usage: copy|equal size iterations\n"); return 1 }
    let operation = args[0]
    let size = int(args[1])
    let iterations = int(args[2])
    if ((operation != "copy" && operation != "equal") || size < 1 || iterations < 1) { return 1 }
    var vm <- init_vm()
    var inscope source : array<Val>
    for (i in range(size + 1)) { push(source, number(vm, int64(i))) }
    let owner = vector(vm, source)
    let tail = rest_list(vm, owner)
    var inscope output <- items(vm, tail)
    var inscope expected := output
    let other = list(vm, expected)
    var success = true
    let start = ref_time_ticks()
    if (operation == "copy") {
        for (i in range(iterations)) { copy_items(vm, tail, output) }
    } else {
        for (i in range(iterations)) {
            if (!equal(vm, tail, other)) { success = false; break }
        }
    }
    let elapsed = get_time_nsec(start)
    if (!success || length(output) != size || numeric(vm, output[size - 1]) != int64(size)) { return 1 }
    print("BENCH iterations={iterations} eval_ns={elapsed} gc_ns=0 peak_values={length(vm.values)} peak_envs={length(vm.envs)} result={operation}\n")
    return 0
}
