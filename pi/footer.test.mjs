import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire, registerHooks } from 'node:module';
import { realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const requireFromPi = createRequire(realpathSync(process.env.PI_BIN || execFileSync('which', ['pi'], { encoding: 'utf8' }).trim()));
registerHooks({ resolve(specifier, context, nextResolve) {
  if (specifier === '@earendil-works/pi-tui') return nextResolve(requireFromPi.resolve(specifier), context);
  return nextResolve(specifier, context);
} });
const { visibleWidth } = await import(requireFromPi.resolve('@earendil-works/pi-tui'));
const { default: footer } = await import('./extensions/personal-footer.ts');

function setup(cwd = '/tmp/example') {
  const handlers = new Map();
  const calls = [];
  const statuses = new Map();
  const pi = {
    on: (event, handler) => handlers.set(event, handler),
    exec: async (cmd, args, options) => {
      calls.push([cmd, args, options]);
      if (cmd === 'git') return { code: 0, stdout: '/tmp/example\n', stderr: '' };
      if (cmd === 'gh') return { code: 0, stdout: '{"url":"https://github.com/other-org/other-repo/pull/42","state":"OPEN"}', stderr: '' };
      if (cmd === 'hud') return { code: 0, stdout: '☁️ 0/2\n', stderr: '' };
      throw Error(cmd);
    },
  };
  let footerFactory;
  const ctx = { cwd, mode: 'tui', model: { id: 'test-model', contextWindow: 1000 },
    getContextUsage: () => ({ percent: 10, contextWindow: 1000 }),
    sessionManager: { getCwd: () => cwd, getSessionName: () => undefined, getEntries: () => [] },
    ui: {
      setStatus: (key, value) => value === undefined ? statuses.delete(key) : statuses.set(key, value),
      setFooter: (factory) => { footerFactory = factory; },
    } };
  footer(pi);
  return { handlers, calls, statuses, ctx, pi, render: (width = 140) => footerFactory(
    { requestRender() {} }, { fg: (_color, text) => text },
    { getGitBranch: () => 'feature', getExtensionStatuses: () => statuses,
      onBranchChange: () => () => {}, getAvailableProviderCount: () => 1 },
  ).render(width) };
}

test('renders PR and other statuses above the bottommost hud line', async () => {
  const { handlers, calls, statuses, render, ctx } = setup();
  await handlers.get('session_start')({}, ctx);
  assert.equal(statuses.has('personal-hud'), false);
  assert.equal(statuses.get('personal-pr'), 'https://github.com/other-org/other-repo/pull/42');
  statuses.set('ganglia-budget', 'budget $1/$100');
  const lines = render();
  assert.match(lines[0], /feature/);
  assert.match(lines[1], /test-model/);
  assert.match(lines[2], /budget \$1\/\$100/);
  assert.match(lines[2], /https:\/\/github.com\/other-org\/other-repo\/pull\/42/);
  assert.equal(lines.at(-1), '☁️ 0/2');
  assert.deepEqual(calls.find(([cmd]) => cmd === 'gh')[1], ['pr', 'view', '--json', 'url,state']);
  assert.equal(calls.find(([cmd]) => cmd === 'gh')[2].cwd, '/tmp/example');
});

test('no PR clears the PR entry but keeps hud', async () => {
  const { handlers, pi, statuses, render, ctx } = setup();
  pi.exec = async (cmd) => cmd === 'gh' ? { code: 1, stdout: '', stderr: '' } : { code: 0, stdout: cmd === 'git' ? '/tmp/example\n' : '♥ 2/5', stderr: '' };
  await handlers.get('session_start')({}, ctx);
  assert.equal(statuses.get('personal-pr'), undefined);
  assert.equal(render().at(-1), '♥ 2/5');
});

test('outside a git repo, only hud is shown', async () => {
  const { handlers, pi, calls, statuses, render, ctx } = setup();
  pi.exec = async (cmd, args, options) => {
    calls.push([cmd, args, options]);
    return { code: cmd === 'git' ? 128 : 0, stdout: cmd === 'hud' ? '☁️ 0/2' : '', stderr: '' };
  };
  await handlers.get('session_start')({}, ctx);
  assert.equal(statuses.get('personal-pr'), undefined);
  assert.equal(render().at(-1), '☁️ 0/2');
  assert.equal(calls.some(([cmd]) => cmd === 'gh'), false);
});

test('non-tui sessions never run footer commands', async () => {
  const { handlers, calls, ctx } = setup();
  ctx.mode = 'print';
  await handlers.get('session_start')({}, ctx);
  assert.equal(calls.length, 0);
});

test('hud is bottommost even without a PR; narrow widths stay bounded', async () => {
  const { handlers, statuses, ctx, render } = setup();
  await handlers.get('session_start')({}, ctx);
  statuses.delete('personal-pr');
  assert.equal(render().length, 3);
  assert.equal(render().at(-1), '☁️ 0/2');
  assert.ok(render(12).every((line) => visibleWidth(line) <= 12));
});

test('turn end refreshes both entries', async () => {
  const { handlers, calls, ctx } = setup();
  await handlers.get('session_start')({}, ctx);
  await handlers.get('turn_end')({}, ctx);
  assert.equal(calls.filter(([cmd]) => cmd === 'hud').length, 2);
  assert.equal(calls.filter(([cmd]) => cmd === 'gh').length, 2);
});

const ESC = '\x1b';
const strip = (text) => text.replace(/\x1b\[[0-9;]*m/g, '');
const fg = (r, g, b) => `${ESC}[38;2;${r};${g};${b}m`;

async function statsLine(tokens, contextWindow = 1_000_000) {
  const { handlers, ctx, render } = setup();
  ctx.getContextUsage = () => ({ tokens, contextWindow, percent: tokens === null ? null : tokens / contextWindow * 100 });
  await handlers.get('session_start')({}, ctx);
  return render()[1];
}

test('context shows k tokens, not a percentage', async () => {
  const line = await statsLine(77_227);
  assert.match(strip(line), /ctx: 77k/);
  assert.doesNotMatch(strip(line), /%/);
});

test('context is green up to 100k, yellow at 150k, red from 200k', async () => {
  assert.ok((await statsLine(100_000)).includes(`${fg(80, 180, 80)}ctx: 100k`));
  assert.ok((await statsLine(150_000)).includes(`${fg(200, 170, 60)}ctx: 150k`));
  assert.ok((await statsLine(200_000)).includes(`${fg(210, 70, 70)}ctx: 200k`));
  assert.ok((await statsLine(640_000)).includes(`${fg(210, 70, 70)}ctx: 640k`));
});

test('context color is interpolated between the stops', async () => {
  assert.ok((await statsLine(125_000)).includes(`${fg(140, 175, 70)}ctx: 125k`));
  assert.ok((await statsLine(175_000)).includes(`${fg(205, 120, 65)}ctx: 175k`));
});

test('color ignores window size', async () => {
  assert.ok((await statsLine(200_000, 200_000)).includes(`${fg(210, 70, 70)}ctx: 200k`));
});

test('unknown tokens right after compaction show ctx: ?', async () => {
  assert.match(strip(await statsLine(null)), /ctx: \?/);
});

test('model stays right-aligned and the line stays within width', async () => {
  const { handlers, ctx, render } = setup();
  ctx.getContextUsage = () => ({ tokens: 150_000, contextWindow: 1_000_000, percent: 15 });
  await handlers.get('session_start')({}, ctx);
  const line = render(100)[1];
  assert.equal(visibleWidth(line), 100);
  assert.ok(strip(line).endsWith('test-model'));
  assert.ok(render(12).every((l) => visibleWidth(l) <= 12));
});
