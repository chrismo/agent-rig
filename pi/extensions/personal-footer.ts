import { homedir } from "node:os";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

function tokens(n: number) {
  return n < 1000 ? `${n}` : n < 10000 ? `${(n / 1000).toFixed(1)}k` : `${Math.round(n / 1000)}k`;
}

type Rgb = [number, number, number];
const GREEN: Rgb = [80, 180, 80];
const YELLOW: Rgb = [200, 170, 60];
const RED: Rgb = [210, 70, 70];

function lerp(from: Rgb, to: Rgb, step: number): Rgb {
  return from.map((c, i) => Math.trunc(c + (to[i] - c) * step / 50_000)) as Rgb;
}

// Same gradient as statusline/plugins.d/2.10-context.
function contextColor(tokens: number): Rgb {
  if (tokens <= 100_000) return GREEN;
  if (tokens >= 200_000) return RED;
  return tokens <= 150_000 ? lerp(GREEN, YELLOW, tokens - 100_000) : lerp(YELLOW, RED, tokens - 150_000);
}

export default function (pi: ExtensionAPI) {
  let timer: ReturnType<typeof setInterval> | undefined;
  let hud = "";
  let renderFooter = () => {};

  async function refreshHud(ctx: ExtensionContext) {
    try {
      const result = await pi.exec("hud", ["bar"], { timeout: 3000, cwd: ctx.cwd });
      hud = result.code === 0 ? result.stdout.trim().replace(/[\r\n]/g, " ") : "";
    } catch {
      hud = "";
    }
    renderFooter();
  }

  async function refreshPr(ctx: ExtensionContext) {
    try {
      const root = await pi.exec("git", ["rev-parse", "--show-toplevel"], { cwd: ctx.cwd, timeout: 3000 });
      if (root.code !== 0) {
        ctx.ui.setStatus("personal-pr", undefined);
        return;
      }
      const result = await pi.exec("gh", ["pr", "view", "--json", "url,state"], { cwd: root.stdout.trim(), timeout: 5000 });
      const pr = result.code === 0 ? JSON.parse(result.stdout) : null;
      ctx.ui.setStatus("personal-pr", pr?.url ? `${pr.url}${pr.state === "OPEN" ? "" : ` (${pr.state.toLowerCase()})`}` : undefined);
    } catch {
      ctx.ui.setStatus("personal-pr", undefined);
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    ctx.ui.setFooter((tui, theme, data) => {
      const unsubscribe = data.onBranchChange(() => tui.requestRender());
      renderFooter = () => tui.requestRender();
      return {
        dispose() { unsubscribe(); renderFooter = () => {}; },
        invalidate() {},
        render(width: number): string[] {
          const cwd = ctx.sessionManager.getCwd();
          const home = homedir();
          const path = cwd === home ? "~" : cwd.startsWith(`${home}/`) ? `~${cwd.slice(home.length)}` : cwd;
          const branch = data.getGitBranch();
          const name = ctx.sessionManager.getSessionName();
          const location = `${path}${branch ? ` (${branch})` : ""}${name ? ` • ${name}` : ""}`;

          let input = 0, output = 0, cacheRead = 0, cacheWrite = 0, cost = 0;
          for (const entry of ctx.sessionManager.getEntries()) {
            if (entry.type === "message" && entry.message.role === "assistant") {
              const usage = (entry.message as AssistantMessage).usage;
              input += usage.input;
              output += usage.output;
              cacheRead += usage.cacheRead;
              cacheWrite += usage.cacheWrite;
              cost += usage.cost.total;
            }
          }
          const contextTokens = ctx.getContextUsage()?.tokens ?? null;
          const contextText = contextTokens === null ? "ctx: ?" : `ctx: ${Math.round(contextTokens / 1000)}k`;
          const stats = [
            input && `↑${tokens(input)}`, output && `↓${tokens(output)}`,
            cacheRead && `R${tokens(cacheRead)}`, cacheWrite && `W${tokens(cacheWrite)}`,
            cost && `$${cost.toFixed(3)}`,
          ].filter(Boolean).join(" ");
          const statsPrefix = stats && `${stats} `;
          const contextStyled = contextTokens === null
            ? theme.fg("dim", contextText)
            : `\x1b[38;2;${contextColor(contextTokens).join(";")}m${contextText}\x1b[39m`;
          const model = ctx.model?.id ?? "no-model";
          const right = ctx.model?.reasoning ? `${model} • ${ctx.thinkingLevel ?? "off"}` : model;
          const gap = " ".repeat(Math.max(2, width - visibleWidth(statsPrefix + contextText) - visibleWidth(right)));
          const lines = [
            truncateToWidth(theme.fg("dim", location), width),
            truncateToWidth(theme.fg("dim", statsPrefix) + contextStyled + theme.fg("dim", gap + right), width),
          ];
          const statuses = [...data.getExtensionStatuses().entries()]
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([, text]) => text.replace(/[\r\n\t]/g, " "));
          if (statuses.length) lines.push(truncateToWidth(statuses.join(" "), width));
          if (hud) lines.push(truncateToWidth(hud, width));
          return lines;
        },
      };
    });
    await Promise.all([refreshHud(ctx), refreshPr(ctx)]);
    if (timer) clearInterval(timer);
    timer = setInterval(() => void refreshHud(ctx), 30_000);
    timer.unref();
  });

  pi.on("turn_end", async (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    await Promise.all([refreshHud(ctx), refreshPr(ctx)]);
  });

  pi.on("session_shutdown", () => {
    if (timer) clearInterval(timer);
    timer = undefined;
    renderFooter = () => {};
  });
}
