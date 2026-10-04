const shadow = 1;
function outer(param, { destructured, other: renamed }, ...rest) {
  let shadow = param + destructured;
  const inner = (x) => x * shadow + renamed;
  for (const item of rest) { inner(item); }
  try { throw new Error(param); } catch (err) { console.error(err, shadow); }
  return class Local { method(arg = param) { return arg + this.x; } };
}
label: for (;;) { break label; }
var unused = function named() { return named; };
