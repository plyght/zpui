interface Point { readonly x: number; y?: number }
type Shape = { kind: "circle"; r: number } | { kind: "square"; s: number };
enum Color { Red = 1, Green }
export abstract class Repo<T extends object> implements Iterable<T> {
  private items: Array<T> = [];
  constructor(protected readonly name: string) {}
  abstract find(id: number): T | undefined;
  *[Symbol.iterator](): Iterator<T> { yield* this.items; }
}
const area = (s: Shape): number => s.kind === "circle" ? Math.PI * s.r ** 2 : s.s ** 2;
declare module "x" { export const y: boolean; }
let v = <unknown>area as any satisfies object;
