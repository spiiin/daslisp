options gen2
options persistent_heap
options gc
options stack = 16777216
require ../runtime.das
require ../memory.das
require daslib/clargs
require daslib/fio

// Repeat the exact timed form of upstream perf1/perf2. Parse and load libraries
// before timing; measure evaluation and safe-point collection separately.
[export]
def main() : int {
    var vm <- init_vm()
    init_core(vm)
    var inscope args <- get_user_args()
    if (length(args) != 2) { print("Usage: perf1|perf2 iterations\n"); return 1 }
    let iterations = int(args[1])
    let source = fread("../tests/{args[0]}.mal")
    rep(vm, source)
    if (vm.thrown >= 0) { print("Error: {pr_str(vm, vm.thrown)}\n"); return 1 }
    var inscope forms <- read_all(vm, source)
    var inscope timed <- items(vm, back(forms))
    let ast = timed[1]
    var eval_ns = 0l
    var gc_ns = 0l
    var peak_values = 0
    var peak_envs = 0
    var result_text = ""
    for (i in range(iterations)) {
        let start = ref_time_ticks()
        let value = eval(vm, ast)
        eval_ns += get_time_nsec(start)
        if (vm.thrown >= 0) { print("Error: {pr_str(vm, vm.thrown)}\n"); return 1 }
        if (i == iterations - 1) { result_text = pr_str(vm, value) }
        if (length(vm.values) > peak_values) { peak_values = length(vm.values) }
        if (length(vm.envs) > peak_envs) { peak_envs = length(vm.envs) }
        let gc_start = ref_time_ticks()
        collect(vm, [ast])
        if (i % 16 == 15) { unsafe { heap_collect(true, false) } }
        gc_ns += get_time_nsec(gc_start)
    }
    print("BENCH iterations={iterations} eval_ns={eval_ns} gc_ns={gc_ns} peak_values={peak_values} peak_envs={peak_envs} result={result_text}\n")
    return 0
}
