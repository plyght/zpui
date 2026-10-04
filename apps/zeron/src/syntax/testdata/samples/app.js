// @ts-check
import { readFile } from "node:fs/promises";
const answer = 42, re = /ab+c/gi;
class Greeter extends Base {
  #secret = null;
  constructor(name) { super(); this.name = name; }
  async greet(times = 1) {
    for (let i = 0; i < times; i++) console.log(`Hello ${this.name}!`);
    return await readFile(__dirname + "/x.txt", "utf8");
  }
}
function outer(param) { const inner = param * 2; return inner ?? undefined; }
export default { answer, Greeter, html: html`<b>${answer}</b>` };
