# Nested injections

Inline <b>bold html</b> and <span class="x">span</span> with `code`.

```dockerfile
FROM node:20
RUN npm ci && \
    npm run build
COPY <<EOT /app/config.yaml
key: value
EOT
```

```html
<style>.x { margin: 0; }</style>
<script>
  const css = String.raw;
  let v = css`a { b: c; }`;
</script>
```

```js
function tag(param) { const local = param; return local ?? css`x { y: z; }`; }
```

```tsx
export const App = ({ title }: { title: string }) => <h1 className="t">{title}</h1>;
```

```jsonc
{ /* c */ "a": [1, 2] }
```

```sh
for i in $(seq 1 3); do echo "$i"; done
```

```kotlin
fun main() = println("hi")
```

```
no language
```

    indented code block

1. **bold _nested italic_ text**
   - [link `code`](http://x.y "t") ~~gone~~
   - <https://example.org>

| a | b |
|---|---|
| `x` | *y* |

$$
x^2
$$
