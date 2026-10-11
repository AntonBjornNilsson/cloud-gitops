// Which Bash commands run without asking. Everything not provably read-only goes to the user as a
// yes/no question: cluster writes, unknown tools, command substitution, redirects to files, env overrides.
export type Verdict = { ok: true } | { ok: false; reason: string };

const TEXT_TOOLS = new Set([
  'jq', 'grep', 'egrep', 'fgrep', 'head', 'tail', 'sort', 'uniq', 'wc', 'cut', 'tr', 'cat', 'ls', 'echo',
  'printf', 'date', 'column', 'diff', 'base64', 'true', 'false', 'test', '[', 'nl', 'tac', 'cd', 'pwd', 'sleep',
  'comm', 'paste', 'fold', 'fmt', 'expand', 'unexpand', 'rev', 'seq', 'od', 'cmp', 'basename', 'dirname',
  'realpath', 'readlink', 'stat', 'du', 'df', 'md5sum', 'sha1sum', 'sha256sum', 'wc', 'id', 'whoami',
  'uname', 'hostname', 'nproc', 'free', 'uptime', 'ps', 'which', 'type', 'zcat',
]);
const KUBECTL_READ = new Set([
  'get', 'describe', 'logs', 'top', 'explain', 'api-resources', 'api-versions', 'version', 'cluster-info',
  'events', 'kustomize', 'diff', 'wait',
]);
const KUBECTL_SUB_READ: Record<string, Set<string>> = {
  auth: new Set(['can-i', 'whoami']),
  config: new Set(['view', 'get-contexts', 'current-context', 'get-clusters']),
};
const FLUX_READ = new Set(['get', 'logs', 'tree', 'stats', 'events', 'check', 'version', 'diff', 'export', 'trace', 'debug', 'build']);
const GIT_READ = new Set([
  'status', 'diff', 'log', 'show', 'ls-files', 'ls-tree', 'grep', 'blame', 'rev-parse', 'show-ref', 'restore', 'checkout',
  'cat-file', 'describe', 'shortlog', 'reflog', 'merge-base', 'name-rev', 'rev-list', 'whatchanged',
]);
// /proc/<pid>/environ holds the pod's tokens; only a few harmless /proc files may be read
const SAFE_PROC = /^\/proc\/(cpuinfo|meminfo|loadavg|uptime|version|mounts|self\/(status|limits|cgroup))$/;
export const sensitivePath = (p: string) => /^\/proc(\/|$)/.test(p) && !SAFE_PROC.test(p);
const FIND_WRITES = new Set(['-exec', '-execdir', '-ok', '-okdir', '-delete', '-fprint', '-fprint0', '-fprintf', '-fls']);
// kubectl global flags that take a separate value, so the verb is found after them
const KUBECTL_VALUE_FLAGS = new Set([
  '-n', '--namespace', '--context', '--kubeconfig', '--cluster', '--user', '-l', '--selector', '-o', '--output',
  '-c', '--container', '-s', '--server', '--request-timeout',
]);

const deny = (reason: string): Verdict => ({ ok: false, reason });

// Splits a command line into simple commands (words), rejecting anything that can run or write
// beyond the words themselves. Redirects are only allowed to /dev/null or between descriptors.
export function parse(cmd: string): { segments: string[][] } | { error: string } {
  if (/\$\(|`|<\(|>\(/.test(cmd)) return { error: 'command substitution' };
  const segments: string[][] = [[]];
  let cur = '';
  let inWord = false;
  let quote: string | null = null;
  const flush = () => {
    if (inWord) segments[segments.length - 1].push(cur);
    cur = '';
    inWord = false;
  };
  const next = () => {
    flush();
    segments.push([]);
  };
  for (let i = 0; i < cmd.length; i++) {
    const c = cmd[i];
    if (quote === "'") {
      if (c === "'") quote = null;
      else cur += c;
      continue;
    }
    if (quote === '"') {
      if (c === '"') quote = null;
      else if (c === '\\' && i + 1 < cmd.length) cur += cmd[++i];
      else cur += c;
      continue;
    }
    if (c === "'" || c === '"') {
      quote = c;
      inWord = true;
      continue;
    }
    if (c === '\\') {
      if (cmd[i + 1] === '\n') i++;
      else {
        cur += cmd[++i] ?? '';
        inWord = true;
      }
      continue;
    }
    if (c === '\n' || c === ';') {
      next();
      continue;
    }
    if (c === ' ' || c === '\t') {
      flush();
      continue;
    }
    if (c === '|') {
      if (cmd[i + 1] === '|' || cmd[i + 1] === '&') i++;
      next();
      continue;
    }
    if (c === '&' && cmd[i + 1] === '&') {
      i++;
      next();
      continue;
    }
    if (c === '<') return { error: 'input redirect or here-doc' };
    if (c === '>' || (c === '&' && cmd[i + 1] === '>')) {
      // A digits-only word right before ">" is the file descriptor, not an argument
      if (/^\d+$/.test(cur)) {
        cur = '';
        inWord = false;
      } else flush();
      let j = c === '&' ? i + 2 : i + 1;
      if (cmd[j] === '>') j++;
      if (cmd[j] === '&') {
        // 2>&1 style duplication
        j++;
        while (/\d|-/.test(cmd[j] ?? '')) j++;
        i = j - 1;
        continue;
      }
      while (cmd[j] === ' ') j++;
      let target = '';
      while (j < cmd.length && !/[\s;|&]/.test(cmd[j])) target += cmd[j++];
      if (target !== '/dev/null') return { error: `redirect to ${target || 'a file'}` };
      i = j - 1;
      continue;
    }
    if (c === '&') return { error: 'background job' };
    cur += c;
    inWord = true;
  }
  if (quote) return { error: 'unterminated quote' };
  flush();
  return { segments: segments.filter((s) => s.length > 0) };
}

function kubectlVerb(args: string[]): { verb?: string; rest: string[] } {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (KUBECTL_VALUE_FLAGS.has(a)) {
      i++;
      continue;
    }
    if (a.startsWith('-')) continue;
    return { verb: a, rest: args.slice(i + 1) };
  }
  return { rest: [] };
}

function readsSecretContents(args: string[]): boolean {
  const mentionsSecret = args.some((a) => /(^|[,/])secrets?($|[,/])/i.test(a));
  if (!mentionsSecret) return false;
  if (args.some((a) => a === '--raw' || a.startsWith('--raw='))) return true;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    let fmt: string | undefined;
    if (a === '-o' || a === '--output') fmt = args[i + 1];
    else if (a.startsWith('--output=')) fmt = a.slice(9);
    else if (a.startsWith('-o') && a.length > 2) fmt = a.slice(2).replace(/^=/, '');
    if (fmt !== undefined && !/^(name|wide)$/.test(fmt)) return true;
  }
  return false;
}

// awk is read-only unless its program runs commands, reads other input, writes files or reads the environment
function checkAwk(args: string[]): Verdict {
  let program: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-f' || a.startsWith('--file') || /^-[^-]*f/.test(a) && !/^-F/.test(a)) return deny('awk with a script file');
    if (a === '-F' || a === '-v') {
      i++;
      continue;
    }
    if (a.startsWith('-')) continue;
    program = a;
    break;
  }
  if (program === undefined) return { ok: true };
  if (/system\s*\(|getline|ENVIRON|\||\b(print|printf)\b[^;}]*>|close\s*\(|fflush/.test(program)) {
    return deny('awk program runs commands, reads input or writes output');
  }
  return { ok: true };
}

// sed is read-only for printing and substitution; no in-place edits, script files or w/e/r commands
function checkSed(args: string[]): Verdict {
  const scripts: string[] = [];
  let sawScript = false;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '-i' || a.startsWith('-i') || a.startsWith('--in-place') || a === '-f' || a.startsWith('--file') || a === '-s') {
      return deny('sed editing in place or reading a script file');
    }
    if (a === '-e' || a === '--expression') {
      scripts.push(args[++i] ?? '');
      sawScript = true;
      continue;
    }
    if (/^-[nErzu]+$/.test(a) || a === '--quiet' || a === '--silent' || a === '--regexp-extended') continue;
    if (a.startsWith('-')) return deny(`sed ${a}`);
    if (!sawScript) {
      scripts.push(a);
      sawScript = true;
    }
  }
  const simple = /^(\d+|\$|\/[^/]*\/)?(,(\d+|\$|\/[^/]*\/))?!?[pdq=]$/;
  for (const script of scripts) {
    for (const cmd of script.split(/[;\n]/).map((c) => c.trim()).filter(Boolean)) {
      if (simple.test(cmd)) continue;
      const sub = cmd.match(/^(\d+|\$|\/[^/]*\/)?(,(\d+|\$|\/[^/]*\/))?s(.)(.*)\4(.*)\4([^\s]*)$/);
      if (sub && !/[we]/.test(sub[7]) && !sub[5].includes(sub[4]) && !sub[6].includes(sub[4])) continue;
      return deny(`sed command "${cmd.slice(0, 40)}" is not a print or substitution`);
    }
  }
  return { ok: true };
}

// xargs runs another command; it is as safe as that command
const XARGS_VALUE_FLAGS = new Set(['-n', '-I', '-P', '-L', '-d', '-s', '-E', '-a', '--max-args', '--replace', '--max-procs', '--delimiter']);
function checkXargs(args: string[]): Verdict {
  let i = 0;
  for (; i < args.length; i++) {
    if (XARGS_VALUE_FLAGS.has(args[i])) i++;
    else if (!args[i].startsWith('-')) break;
  }
  const rest = args.slice(i);
  return rest.length ? checkSimple(rest) : { ok: true };
}

function checkSimple(words: string[]): Verdict {
  const [cmd, ...args] = words;
  if (/^\w+=/.test(cmd)) return deny('sets environment variables');
  const paths = [cmd, ...args].flatMap((a) => [a, a.replace(/^[^=]*=/, '')]);
  if (paths.some(sensitivePath)) return deny('reads /proc (process environments hold tokens)');
  const name = cmd.split('/').pop()!;
  if (TEXT_TOOLS.has(name)) return { ok: true };
  if (name === 'awk' || name === 'gawk' || name === 'mawk') return checkAwk(args);
  if (name === 'sed') return checkSed(args);
  if (name === 'xargs') return checkXargs(args);
  if (name === 'find') return args.some((a) => FIND_WRITES.has(a)) ? deny('find with an action') : { ok: true };
  if (name === 'kubectl') {
    const { verb, rest } = kubectlVerb(args);
    if (!verb) return { ok: true };
    if (KUBECTL_SUB_READ[verb]) return KUBECTL_SUB_READ[verb].has(rest[0]) ? { ok: true } : deny(`kubectl ${verb} ${rest[0] ?? ''}`.trim());
    if (!KUBECTL_READ.has(verb)) return deny(`kubectl ${verb} changes the cluster`);
    if (readsSecretContents(args)) return deny('reads Secret contents');
    return { ok: true };
  }
  if (name === 'flux') {
    const verb = args.find((a) => !a.startsWith('-'));
    return !verb || FLUX_READ.has(verb) ? { ok: true } : deny(`flux ${verb} changes the cluster`);
  }
  if (name === 'git') {
    const verb = args.find((a) => !a.startsWith('-'));
    return verb && GIT_READ.has(verb) ? { ok: true } : deny(`git ${verb ?? ''}`.trim());
  }
  return deny(`${name} is not on the read-only list`);
}

export function checkCommand(cmd: string): Verdict {
  const parsed = parse(cmd);
  if ('error' in parsed) return deny(parsed.error);
  for (const words of parsed.segments) {
    const v = checkSimple(words);
    if (!v.ok) return v;
  }
  return { ok: true };
}
