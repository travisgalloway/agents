# UX lens

Method for `/ux-audit` and the UX lens of `/audit`. Read `review-method.md` first. This file adds
the static pass, the live pass, their denominators, and their `n/a` conditions. Finding prefix:
`UX`.

**`n/a` for the whole lens.** Nothing corroborates a user interface: no component framework in the
dependencies, no template directory, no HTML entry point. A CLI-only repository reports `n/a` and
names the dependencies it checked.

## Pass U1: static review of the interface source

**Enumerate first.** Components, and routes or screens. Print both counts. The positive control is
the framework's own marker over the same file set, such as `export default` in `.svelte` or `.vue`
files, or a JSX return in `.tsx` files.

| Rule slug | Check | Severity |
|---|---|---|
| `input-no-label` | a form control with no associated label, `aria-label`, or `aria-labelledby` | medium |
| `img-no-alt` | an image with no `alt` attribute. An empty `alt` on a decorative image is correct | medium |
| `click-on-non-interactive` | a click handler on a `div` or `span` with no role, no `tabindex`, and no key handler | medium |
| `focus-lost` | a modal, drawer, or route change that neither moves focus nor returns it on close | medium |
| `missing-async-state` | a component that fetches data and renders no loading, error, or empty state | medium |
| `destructive-no-confirm` | a delete or irreversible action with no confirmation and no undo | high |
| `hardcoded-color` | a literal color where the repository defines design tokens or theme variables | low |
| `copy-inconsistent` | the same action or object named two ways across the interface | low |

**`missing-async-state` needs the three states checked separately.** A component can handle
loading and still render nothing on an empty list. Each missing state is its own row, with the
state named in `symbol`.

**`hardcoded-color` is `n/a` when the repository defines no tokens.** Check for a tokens file, CSS
custom properties on `:root`, or a theme config before reporting any row.

## Pass U2: the running interface

U2 runs in its own subagent, because it holds a browser and a server process for its whole run.

### Starting the app

1. Read `{repo_root}/.claude/ux-audit.json` when it exists. It may set `baseUrl`, `startCommand`,
   `routes`, `readyPath`, and `storageState`.
2. Otherwise take `startCommand` from the project's dev script (`dev`, `start`, or `serve` in
   `package.json`, or the stack's equivalent) and `baseUrl` from its configured port.
3. Start it detached, capture its PID from `$!` on the same line, and poll for readiness:

```bash
# $! on the starting line is the only reliable PID; `jobs -p` returns nothing under `zsh -c`.
cd "$repo_root" && nohup sh -c "$start_command" > "$run_dir/ux/server.log" 2>&1 & srv_pid=$!
printf '%s\n' "$srv_pid" > "$run_dir/ux/server.pid"
ready=0
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "$base_url${ready_path:-/}"; then ready=1; break; fi
  kill -0 "$srv_pid" 2>/dev/null || break
  sleep 1
done
```

4. **The server process is ended before the pass returns**, on every path, including a failure:

```bash
# Walk the descendants, because `npm run dev` spawns the real server as a grandchild. Never signal
# the process group: without job control the background job shares this shell's group.
pids="$srv_pid"; frontier="$srv_pid"
while [ -n "$frontier" ]; do
  next=""
  for p in $(echo $frontier); do next="$next $(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')"; done
  frontier=$(echo $next); pids="$pids $frontier"
done
for p in $(echo $pids); do kill -TERM "$p" 2>/dev/null; done
sleep 2
for p in $(echo $pids); do kill -0 "$p" 2>/dev/null && kill -KILL "$p"; done
ps -p "$(echo $pids | tr ' ' ',')" -o pid= 2>/dev/null   # empty output means every PID is gone
```

State the PID and whether it is gone on the pass's one-line return.

**If `ready` is still 0, U2 is BLIND.** Name the start command and the last lines of
`server.log`. U1 still reports.

### Routes

Take routes from `ux-audit.json` when it lists them. Otherwise take them from the router or the
file-based routes U1 enumerated. Dynamic segments need a real value. Take one from fixtures or
seed data, and list the route as UNAUDITED when none exists.

**Auth-gated routes.** When `storageState` is set, load it into the browser context. Without it,
a route that redirects to a login page is UNAUDITED, never clean. The pass never types credentials.

**Denominator.** Routes visited, over routes enumerated.

### Checks, per route

Drive the Playwright MCP tools (`browser_navigate`, `browser_resize`, `browser_snapshot`,
`browser_take_screenshot`, `browser_evaluate`, `browser_press_key`, `browser_console_messages`).

1. At widths of 375, 768 and 1280 px: take a screenshot to `$run_dir/ux/{route}-{width}.png`, and
   check for horizontal overflow with
   `document.documentElement.scrollWidth > document.documentElement.clientWidth`.
2. Run axe. Load it from the repository's `node_modules/axe-core/axe.min.js` when present, and
   from cdnjs otherwise. Report `serious` and `critical` violations. A failed load makes the axe
   check BLIND for the run, and the other checks continue.
3. Press Tab through the page, up to 50 stops. Record whether focus is visible at each stop, and
   whether any stop traps focus.
4. Collect console errors and failed network requests from the page load.

| Rule slug | Finding | Severity |
|---|---|---|
| `axe-violation` | an axe `serious` or `critical` result, one row per rule per route | medium |
| `overflow-mobile` | horizontal overflow at 375 px | medium |
| `focus-invisible` | a Tab stop with no visible focus indicator | medium |
| `focus-trap` | focus cannot leave a region by keyboard | high |
| `console-error` | an uncaught error or a failed request on load | medium |

For live findings, `file` is the route path and `symbol` is the axe rule or the element selector.
Rule 2's hash input stays stable across runs because neither value carries a line number.

**`live=off`** skips U2. The coverage line prints `U2 skipped (live=off)`, which differs from both
`n/a` and BLIND.
