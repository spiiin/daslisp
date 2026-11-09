# daslisp

A Lisp interpreter written in [daScript](https://github.com/GaijinEntertainment/daScript), following the [Make a Lisp (MAL)](https://github.com/kanaka/mal/blob/master/process/guide.md) guide through the final step A. The reader grammar is written in **dasPEG**. The [Nim implementation write-up](https://hookrace.net/blog/make-a-lisp-in-nim/) served as a reference.

- Passes **923/923** upstream MAL tests for steps 1–A, and runs the self-hosted MAL interpreter (`impls/mal/stepA_mal.mal`) on top of itself.
- Proper tail calls, an iterative mark-and-sweep GC that can run in the middle of an evaluation, and O(1) shared list tails.
- Runs interpreted, under the daScript LLVM JIT, or compiled to C++ (AOT).

## Requirements

- daScript / Daslang SDK **0.6.5-RC2 or newer** (must include the bundled `peg/peg` module). No C++ build or third-party libraries are needed.
- Python 3.8+ for the test and benchmark scripts (optional).

## Usage

```sh
daslang main.das                                # interactive REPL
daslang main.das -- --eval '(+ 2 (* 3 4))'      # 14
daslang main.das -- examples/demo.mal           # run a file
daslang main.das -- program.mal arg1 arg2       # arguments are available as *ARGV*
echo '(+ 1 2)' | daslang main.das -- --batch    # piped input, no prompts
echo "'foo" | daslang main.das -- --read        # reader/printer only: (quote foo)
```

On Windows, `run.ps1` wraps the same commands. It looks for `DASLANG_EXE`, then `daslang` on `PATH`, then a sibling daScript checkout; pass `-Daslang PATH` to override.

```powershell
./run.ps1                                       # REPL
./run.ps1 -Eval '(+ 2 (* 3 4))'
./run.ps1 -Script examples/demo.mal arg1 arg2
'(+ 1 2)' | ./run.ps1 -Batch
```

Files may contain multi-line forms and comments. In the REPL each line is one unit of input and EOF exits. Errors print as `Error: ...` and the REPL (and `--batch`) keeps going; an error in a file or `--eval` exits with a non-zero code.

To run under the JIT:

```sh
daslang -jit main.das -- --eval '(+ 1 2)'
```

## Language

- `nil`, booleans, int64, strings, symbols, keywords, lists, vectors, and hash maps with string and keyword keys.
- `def!`, `let*`, `do`, `if`, `fn*`: lexical closures, recursion, mutual recursion, rest parameters via `&`.
- Tail calls through the evaluator loop; `quote`, `quasiquote`, `unquote`, `splice-unquote`.
- `defmacro!`, `cond`, `macroexpand`, `quasiquoteexpand`; reader shorthands `'`, `` ` ``, `~`, `~@`, `@`, `^`.
- `try*` / `catch*`, and `throw` with any Lisp value.
- Arithmetic, comparisons, collection functions, `map`, `apply`, atoms, metadata, `read-string`, `eval`, `slurp`, `load-file`, `readline`, `time-ms`, `*ARGV*`, `*host-language*`.
- Arity, type, index and malformed-form errors are reported as Lisp errors.

```clojure
(def! make-adder (fn* [x] (fn* [y] (+ x y))))
(def! add2 (make-adder 2))
(map add2 [1 2 3])                         ; (3 4 5)

(defmacro! unless
  (fn* [condition & body]
    `(if ~condition nil (do ~@body))))
(unless false (println "hello"))

(try* (/ 1 0) (catch* e (str "caught: " e)))
```

## Project layout

| File | Purpose |
| --- | --- |
| `reader.das` | Recursive dasPEG grammar for forms, strings, comments and reader macros. Builds a syntax tree that is then lowered into the VM. |
| `types.das` | `variant Data`, values, closures, environments and typed helpers. |
| `printer.das` | Printer built on `match` and string builders. |
| `runtime.das` | Evaluator, tail calls, macro expansion and built-in functions. |
| `memory.das` | Iterative mark-and-sweep collection of values and environments with slot reuse. |
| `main.das` | REPL, piped input, file execution and command-line handling. |
| `line_input.das` | Full-line input shared by the REPL and `readline`, including lines longer than the `fgets` buffer. |
| `bench_main.das` | Entry point used for benchmarks (same execution path as `main.das`, JIT/AOT friendly). |
| `tests/` | daScript regression tests. |
| `tools/` | Python test runners, MAL benchmark runner and micro-benchmarks. |

## Implementation notes

- **Values are arena indices.** `Val` is an integer handle into the VM arena, so cycles such as `environment → closure → environment` and cyclic atoms are representable without reference counting. VM state is passed explicitly; there is no global current environment.
- **Garbage collection.** The evaluator records its live roots (current forms, environments, intermediate results), so the Lisp GC can run during long computations, not only between REPL lines. The initial threshold is 16,384 allocations and grows with the live set. Marking is iterative, including metadata and cyclic atoms. The SDK's own heap and string heap are collected at input boundaries.
- **Shared list tails.** `rest` returns an immutable O(1) view (`ListTail`) over the original list or vector instead of copying. Repeated `rest` always points at the original owner, so views never chain. A live tail keeps the whole owner alive; use `(apply list tail)` to get a compact independent copy.
- **Symbols** are weakly interned and environments are keyed by symbol handles rather than strings. Unused names are dropped during collection, so macro-generated symbols are not retained forever.
- **Built-ins** are `NativeOp` values dispatched through `match`. Closure arity and rest parameters are validated once, when the function is created.
- **Pointers** are used only locally in two operations (materializing a tail with `memcpy` and comparing two slices). Intervals are validated before any pointer is taken, and pointers never escape those functions. All Lisp-level checks remain enabled.

### Embedding

```das
var vm <- init_vm()
init_core(vm)
rep(vm, "(+ 1 2)")              // or read_all / eval
```

- After evaluation, `vm.thrown >= 0` holds a thrown Lisp value; reset it to `-1` once handled.
- Use `set_binding(vm, env, name, value)` and `lookup` for host bindings, and `symbol(vm, name)` to obtain canonical symbols (do not construct symbol `Data` directly).
- To keep a `Val` alive across another evaluation, pin it with `with_roots(vm, [value]) $() : Val { ... }`. Between evaluations, `collect(vm, roots)` runs the Lisp GC with additional external roots.
- Collect the daScript heap at the top level, as `main.das` does, with `options gc` and `options persistent_heap`.

## Tests

```powershell
./run.ps1 -Test
```

This runs the daScript regression suites (reader/evaluator/GC including 100,000 tail calls and forced in-evaluation collection, shared tails, slice buffers, `apply` root safety), the CLI tests (`tools/test_cli.py`) and the MAL runner self-tests (`tools/test_runner.py`). Individual suites can be run directly, e.g. `daslang tests/test_lisp.das`.

To run the upstream MAL test suite, point at a checkout of [kanaka/mal](https://github.com/kanaka/mal):

```sh
git clone https://github.com/kanaka/mal.git ../mal
python tools/test_mal.py --daslang daslang --mal ../mal --self-host
# or: ./run.ps1 -Test -MalRoot ../mal
```

`tools/test_mal.py` reads the original test files, starts a fresh VM per step and treats deferrable/optional/soft tests as required. Step 1 runs in reader mode; steps 2–A run on the final evaluator. `--self-host` also runs MAL implemented in MAL on top of daslisp.

## Benchmarks

```sh
python tools/bench_mal.py --daslang daslang --mal ../mal --repeat 3 --fixed-iterations 200 --output benchmarks.json
# or: ./run.ps1 -Bench -MalRoot ../mal
```

This runs the unmodified MAL `perf1.mal`, `perf2.mal` and `perf3.mal`. `--fixed-iterations` additionally repeats the exact timed form of `perf1`/`perf2` via `tools/bench_eval.das`, excluding parsing and library loading. On Windows peak private-commit memory is recorded as well. `tools/bench_tails.py` and `tools/bench_buffers.py` are micro-benchmarks for shared tails and slice operations.

### Comparison with other MAL implementations

Unmodified MAL `perf1`–`perf3` at MAL revision `2bbfaa54`, Intel Core i9-14900HX, Windows 11. Short tests were repeated 1000 times after 100 warm-up runs; median of three series (time per repetition, including the MAL loop and GC). `perf3` is iterations per second.

| Implementation | perf1, µs | perf2, µs | perf3, it/s |
| --- | ---: | ---: | ---: |
| Java / HotSpot 8u512 | 116 | 201 | 24537.8 |
| Scala 2.11.4 / HotSpot 8u512 | 148 | 200 | 11243.9 |
| **daslisp, LLVM JIT** | **99** | **260** | **9972.0** |
| **daslisp, C++ AOT** | **126** | **339** | **7834.4** |
| JavaScript / Node 22.3.0 | 184 | 481 | 5607.2 |
| Nim 2.4.0, release, markAndSweep | 175 | 653 | 4976.5 |
| **daslisp, interpreted** | **1150** | **2943** | **859.6** |
| Python 3.12.4 | 3227 | 11370 | 302.3 |

The JIT makes daslisp roughly 11–12× faster than the interpreter, AOT about 9×. This compares specific MAL interpreters, not the host languages in general. Raw runs, ranges, memory usage and versions are in [`benchmarks/mal-language-comparison.json`](benchmarks/mal-language-comparison.json). All daScript modes, Scala, Nim, JS and Python pass 923/923 MAL tests; the upstream Java implementation passes 918/923 (metadata without a space after `^`, not used by the benchmarks).

## Limitations

- Numbers are int64. The reader rejects overflowing literals; division by zero and `INT64_MIN / -1` are Lisp errors. `+`, `-` and `*` use host int64 arithmetic.
- Tail calls do not grow the stack, but ordinary non-tail recursion is bounded by the daScript stack. The SDK string heap is collected between inputs, so a long computation producing many unique strings can grow it until the next input.
- `seq` on a string is byte-based; individual elements may be parts of a multi-byte UTF-8 character.
- `read-string` expects exactly one form. The printer limits nesting depth to 128 so cyclic atoms do not print forever. Hash map key order is unspecified.
- `time-ms` uses a monotonic clock relative to process start.

## License

MPL-2.0, see [`LICENSE`](LICENSE). Sources and borrowed bootstrap forms are listed in [`NOTICE`](NOTICE).
