function scope<T>(param: T, opts?: { flag: boolean }): T {
  const local: T = param;
  if (opts?.flag) { let param = 1; return param as unknown as T; }
  return local;
}
namespace NS { export function f(this: Window, ...args: number[]) { return args.length; } }
@decorator() class D { @prop() accessor x = 1; override m(): void {} }
