# M8.3.3 WP2-A3 — H2.15-R1 A01 Native Operator Evidence Collection Handoff

**CANDIDATE — OPERATOR PROCEDURE ONLY; NATIVE EXECUTION NOT PERFORMED; DECISION C PENDING**

Human-operated preparation for **R1-A01 only**, targeting R1-C2. This handoff
implements preparation/evidence handling under the adopted plan; it does not
replace its physical procedure or criteria. **Stop before attempt declaration
and owner launch.** All filenames below are planned, **not yet created**.
No operator block was executed by Codex.

## Authority and source identity

Decisions [A](h2-15-r1-a01-decision-a-adoption.md) and
[B](h2-15-r1-a01-decision-b-authorization.md) are APPROVED. Decision C is
PENDING. B permits the human's custody, non-scanner logger, original-A
preflight and guarded ACL preparation. This Codex task performs none of them.

| Reference | Pinned identity |
| --- | --- |
| Preparation baseline | `feat/barcode-scanner-slice`, `b3a00bc318297f08034a79dc658c5311e7e2b54f` |
| Qualification baseline | `ea3ac49f467e5d246b1ba7dcbe6486119aee3903`; never replace with latest HEAD |
| [Ratified criteria](h2-15-qualification-criteria-r1.md) | SHA-256 `288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad` |
| [Adopted plan](h2-15-r1-execution-plan.md) | Candidate 1, commit `16ea6253ac2d10ea2a27aacac870edaf5b0c6402`; SHA-256 `c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d` |
| Decisions A / B commits | `3b767d4bd62bc7e43dbe40d3ded82cf08131fb40` / `5045709a7011e76101b3bd3805deb5d3a3e426ff` |
| D2 | `~/Scripts/a3-2/ds2208_a3_2.py`; 141,372 bytes; SHA-256 `cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d` |
| S2 | `~/Scripts/a3-2/synthetic-tests.txt`; 14,227 bytes; SHA-256 `4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785` |

Read the [authorization candidate](h2-15-r1-a01-authorization-readiness.md)
and [ratification](h2-15-r1-ratification.md). The
[blocked assessment](h2-15-r1-a01-native-readiness.md) remains accurate for
Codex's runner. The owner's newer native observations are attestations, not
newly preserved campaign originals. No prior gate is promoted to GO here.

Use two independently opened **native Fedora host Bash terminals**, T1/T2,
not Codex, Distrobox, toolbox, SSH or another VM. Keep the scanner aimed at a
blank area; do not scan. Never modify sandbox configuration/detection flags,
scanner programming, modem signals, groups or host policy. No installations,
automatic retries, diagnostic self-tests or off-host transfer. Failure means
STOP, retain partial evidence and seek review; never clean/reuse it for green.

### Capture before custody

N0–N2 original combined stdout/stderr bytes are held in bounded Bash memory
as base64 in JSON capture records. N3 exclusively writes those records and
the exact decoded bytes. This is reversible capture, not reconstructed chat
or scrollback. Metadata records actual argv, terminal role/path, shell/collector/
child PIDs, private boot digest, times, byte count/hash and real exit status.
Expected command status means completion, **never qualification GO**.

Bound: 128 commands per terminal, 65,536 output bytes per command, 98,304 JSON
characters per record. Timeout, overflow, unknown termination or lost buffers
prevents qualification. Keep both terminals open until durable N3 verification.
There is no alternate evidence root. After N3, each new capture flushes at once.
These helpers collect evidence; they are not adapters or qualification runners.
They never capture scanner input. Interactive logger/privileged steps are
separate. Watchdogs cannot guarantee cancellation of uninterruptible kernel
work; a stuck operation requires review, not continued execution.

## Phase N0 — Establish the native command boundary

In each terminal run setup, using `T1` only in terminal 1 and `T2` only in
terminal 2. Do not run both assignments in one shell. Missing initial Python
or Bash prevents automatic capture: stop, retain the terminal error and report
missing evidence; do not install or claim a successful N0.

```bash
h215_role=T1                         # Use T2 in the other native terminal.
[[ "$h215_role" == T1 || "$h215_role" == T2 ]] || exit 1
[[ -n ${BASH_VERSION:-} && $- != *x* ]] || exit 1
[[ ! ${BASH_ENV+x} && ! ${ENV+x} ]] || exit 1
test -t 0 && test -t 1 || exit 1
umask 077
set -o noclobber
h215_repo=/var/home/user/Projects/grocery-pos-platform
cd -P -- "$h215_repo" || exit 1
[[ "$(pwd -P)" == "$h215_repo" ]] || { printf '%s\n' 'STOP: approved repository path mismatch.' >&2; exit 1; }
test "$(type -t python3)" = file || exit 1
h215_python="$(command -v python3)" || exit 1
case "$h215_python" in /*) ;; *) exit 1 ;; esac
test -f "$h215_python" && test -x "$h215_python" || exit 1
h215_shell_pid=$BASHPID
h215_sink=
h215_records=()
h215_count=0
declare -A h215_labels=()
```

Load the collector in both terminals. The `read` EOF status is expected and
handled by the explicit nonempty check. Do not enable shell tracing.

```bash
read -r -d '' h215_collector <<'PYCOLLECT' || [[ -n ${h215_collector:-} ]] || exit 1
import base64,hashlib,json,os,selectors,subprocess,sys,time
from pathlib import Path
role,shell_pid,label,seconds,*argv=sys.argv[1:]
assert role in ("T1","T2") and argv and sum(map(len,argv))<=8192
seconds=int(seconds);assert 1<=seconds<=180
boot=hashlib.sha256(Path("/proc/sys/kernel/random/boot_id").read_bytes()).hexdigest()
pid1=Path("/proc/1/comm").read_text().strip()
r=dict(role=role,caller_shell_pid=int(shell_pid),label=label,collector_pid=os.getpid(),
 collector_parent=os.getppid(),interpreter=sys.executable,tty=os.ttyname(0),pid1=pid1,
 boot_sha256=boot,argv=argv,started_ns=time.monotonic_ns(),
 collector_sha256=hashlib.sha256((os.environ["h215_collector_source"]+"\n").encode()).hexdigest())
data=bytearray();rc=None;failure=None;child=None
if pid1!="systemd" or os.geteuid()==0:failure="native_boundary_not_established"
else:
 try:child=subprocess.Popen(argv,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 except OSError as e:failure="launch_errno_"+str(e.errno)
if child is not None:
 r["child_pid"]=child.pid
 sel=selectors.DefaultSelector();sel.register(child.stdout,selectors.EVENT_READ)
 end=time.monotonic()+seconds
 while sel.get_map():
  if time.monotonic()>=end:failure="command_timeout";break
  for key,_ in sel.select(min(0.1,max(0,end-time.monotonic()))):
   chunk=os.read(key.fd,4096)
   if not chunk:sel.unregister(key.fileobj);continue
   if len(data)+len(chunk)>65536:failure="output_limit_incomplete";break
   data.extend(chunk)
  if failure:break
 sel.close()
 if failure:child.kill()
 try:rc=child.wait(timeout=2)
 except subprocess.TimeoutExpired:
  failure="termination_unconfirmed";child.kill()
  try:rc=child.wait(timeout=2)
  except subprocess.TimeoutExpired:pass
 child.stdout.close()
if hashlib.sha256(Path("/proc/sys/kernel/random/boot_id").read_bytes()).hexdigest()!=boot:failure="boot_changed"
r.update(ended_ns=time.monotonic_ns(),returncode=rc,failure=failure,complete=failure is None,
 output_bytes=len(data),output_sha256=hashlib.sha256(data).hexdigest(),output_b64=base64.b64encode(data).decode())
encoded=json.dumps(r,sort_keys=True);assert len(encoded)<=98304
print(encoded)
PYCOLLECT
h215_record() {
  local label=$1 seconds=$2 allowed=$3 value rc
  shift 3
  [[ "$label" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
  [[ ! ${h215_labels[$label]+present} && $h215_count -lt 128 ]] || return 1
  h215_labels[$label]=used
  h215_count=$((h215_count+1))
  value="$(h215_collector_source="$h215_collector" "$h215_python" -B -c "$h215_collector" \
    "$h215_role" "$h215_shell_pid" "$label" "$seconds" "$@")" || return 1
  h215_records+=("$value")
  if [[ -n "$h215_sink" ]]; then h215_flush || return 1; fi
  printf '%s\n' "$value" | "$h215_python" -B -c '
import base64,json,sys
r=json.load(sys.stdin)
sys.stdout.buffer.write(base64.b64decode(r["output_b64"],validate=True));sys.stdout.flush()
print("\nCAPTURE_EXIT",r["returncode"],"COMPLETE",r["complete"],"FAILURE",r["failure"])
sys.exit(0 if r["complete"] and str(r["returncode"]) in sys.argv[1].split(",") else 1)
' "$allowed"
  rc=$?
  return "$rc"
}
h215_record N0-container 10 1 systemd-detect-virt --container || exit 1
h215_record N0-vm 10 0 systemd-detect-virt --vm || exit 1
h215_record N0-context 10 0 "$h215_python" -B -c '
import json,os,platform
from pathlib import Path
v={}
for line in Path("/etc/os-release").read_text().splitlines():
 k,sep,val=line.partition("=")
 if k in ("ID","VERSION_ID","VARIANT_ID","PRETTY_NAME"):v[k]=val.strip(chr(34))
markers={p:Path(p).exists() for p in ("/run/.containerenv","/.dockerenv","/.flatpak-info")}
flags={k:bool(os.environ.get(k)) for k in ("SSH_CONNECTION","SSH_TTY","container","FLATPAK_ID","SNAP","CODEX_SANDBOX")}
restrictions={}
for line in Path("/proc/self/status").read_text().splitlines():
 k,sep,val=line.partition(":")
 if k in ("NoNewPrivs","Seccomp","NSpid"):restrictions[k]=val.strip()
print(json.dumps(dict(os=v,machine=platform.machine(),kernel=platform.release(),uid=os.geteuid(),
 pid1=Path("/proc/1/comm").read_text().strip(),tty=os.ttyname(0),
 system_manager=Path("/run/systemd/system").is_dir(),ostree_boot=Path("/run/ostree-booted").exists(),
 boot_id=Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
 markers=markers,flags=flags,restrictions=restrictions),sort_keys=True))
assert v.get("ID")=="fedora" and v.get("VERSION_ID")=="44" and v.get("VARIANT_ID")=="kinoite"
assert platform.machine()=="aarch64" and os.geteuid()!=0
assert not any(markers.values()) and not any(flags.values())
assert Path("/run/systemd/system").is_dir()
assert Path("/run/ostree-booted").exists()
' || exit 1
```

Require container result `none` with status 1, not an unrelated error; VM
`vmware`; systemd host context; ordinary intended owner; no container/remote/
sandbox ambiguity. Record actual kernel rather than hardcoding the prior
version. Investigate restrictive process flags instead of clearing them.
T1/T2 must have different terminal paths/shell PIDs and identical private boot
reference. Compare durably in N8. The human attests to the intended VMware
Fusion/M1 guest and independent terminals. Matching OS/boot metadata alone
is insufficient authentication. Do not publish private boot material.

## Phase N1 — Repository and source identity

Both terminals capture read-only results. Known later documentation commits
must be explicitly reviewed and recorded separately from the qualification
baseline. Unexpected changes stop; no reset, clean, stash or substitution.

```bash
read -r -d '' h215_repo_check <<'PYREPOSITORY' || [[ -n ${h215_repo_check:-} ]] || exit 1
import json,os,subprocess,sys
from pathlib import Path
approved=Path("/var/home/user/Projects/grocery-pos-platform")
assert Path(sys.argv[1])==approved and approved.resolve(strict=True)==approved
assert Path.cwd()==approved,"STOP: approved native working-directory mismatch"
overrides=("GIT_DIR","GIT_WORK_TREE","GIT_COMMON_DIR","GIT_INDEX_FILE","GIT_OBJECT_DIRECTORY",
 "GIT_ALTERNATE_OBJECT_DIRECTORIES","GIT_NAMESPACE","GIT_CONFIG","GIT_CONFIG_COUNT",
 "GIT_CONFIG_PARAMETERS","GIT_CONFIG_GLOBAL","GIT_CONFIG_SYSTEM")
assert not any(k in os.environ for k in overrides),"STOP: Git context override requires review"
def git(*args):
 return subprocess.check_output(["git",*args],stderr=subprocess.DEVNULL,timeout=5).decode().strip()
top=git("rev-parse","--show-toplevel");gitdir=git("rev-parse","--absolute-git-dir")
assert top==str(approved) and gitdir==str(approved/".git"),"STOP: Git working-tree identity mismatch"
assert (approved/".git").is_dir() and not (approved/".git").is_symlink()
assert git("rev-parse","--is-inside-work-tree")=="true"
branch=git("branch","--show-current");origin=git("remote","get-url","origin")
assert branch=="feat/barcode-scanner-slice","STOP: unexpected branch"
assert origin=="git@github.com:adarj/grocery-pos-platform.git","STOP: unexpected repository origin"
print(json.dumps(dict(repository_root=top,git_directory=gitdir,branch=branch,origin=origin,
                     head=git("rev-parse","HEAD")),sort_keys=True))
PYREPOSITORY
h215_record N1-root 30 0 "$h215_python" -B -c "$h215_repo_check" "$h215_repo" || exit 1
h215_record N1-branch 10 0 git branch --show-current || exit 1
h215_record N1-head 10 0 git rev-parse HEAD || exit 1
h215_record N1-status 10 0 git status --short --untracked-files=all || exit 1
h215_record N1-index 10 0 git diff --cached --name-only || exit 1
h215_record N1-baseline 10 0 git show --no-patch --format=fuller ea3ac49f467e5d246b1ba7dcbe6486119aee3903 || exit 1
h215_record N1-identities 20 0 "$h215_python" -B -c '
import hashlib,json,subprocess,sys
from pathlib import Path
root=Path("docs/acceptance/m8.3/wp2-a3")
items=[
 ("ea3ac49f467e5d246b1ba7dcbe6486119aee3903","h2-15-qualification-criteria-r1.md","288c66beaf76c34ef00bf25bf4562cff1d42bfa02a56dc7622a0311b25444aad"),
 ("16ea6253ac2d10ea2a27aacac870edaf5b0c6402","h2-15-r1-execution-plan.md","c3d2c50e84a86c66f66bf80322a523657c37ea62ea201224f447c5b1c1ae451d"),
 ("3b767d4bd62bc7e43dbe40d3ded82cf08131fb40","h2-15-r1-a01-decision-a-adoption.md","010a7299ebe2fc489f01aac2218c7f0eef4ffebab85dc96bc6392d3df6b44f29"),
 ("5045709a7011e76101b3bd3805deb5d3a3e426ff","h2-15-r1-a01-decision-b-authorization.md","09b5fa7fece8376aa99ceac4d32102948a1ce15f7da0763ca08e627944e63194")]
rows=[]
for commit,name,digest in items:
 p=root/name;b=p.read_bytes();old=subprocess.check_output(["git","show",f"{commit}:{p}"],timeout=5)
 assert hashlib.sha256(b).hexdigest()==digest==hashlib.sha256(old).hexdigest()
 rows.append(dict(path=str(p),commit=commit,bytes=len(b),sha256=digest))
for p,digest,size in [(Path(sys.argv[1]),"cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d",141372),
 (Path(sys.argv[2]),"4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785",14227)]:
 b=p.read_bytes();assert len(b)==size and hashlib.sha256(b).hexdigest()==digest
 rows.append(dict(path=str(p),bytes=len(b),sha256=digest))
print(json.dumps(rows,sort_keys=True))
' "$HOME/Scripts/a3-2/ds2208_a3_2.py" "$HOME/Scripts/a3-2/synthetic-tests.txt" || exit 1
```

The approved native working tree is the exact physical path above, with its
own direct .git directory, expected branch and existing SSH origin. A different
root, Git override, linked/redirected Git directory or different origin stops
readiness for review; do not search for another clone, change the remote, clear
overrides or create another custody root. Record actual HEAD separately from
the historical qualification baseline and review any known later documentation
commit before proceeding. Repeat the root check in both terminals at N3 entry.

The owner acknowledges [D2/S2 provenance](evidence-index.md#storage-preservation-and-privacy):
91 saved tests, not a new run. Do not execute the synthetic suite or diagnostic
to inspect its interface. Read the approved source only.

## Phase N2 — Native tooling and Bash validation

Independently apply the adopted Bash check exactly in T1/T2:

```bash
test "$(type -t bash)" = file || exit 1
h215_bash="$(command -v bash)" || exit 1
case "$h215_bash" in
  /*) ;;
  *) exit 1 ;;
esac
test -n "$h215_bash" && test -f "$h215_bash" && test -x "$h215_bash" || exit 1
h215_record N2-interpreters 10 0 "$h215_python" -B -c '
import json,os,sys
print(json.dumps(dict(python=sys.executable,version=sys.version,bash=sys.argv[1],uid=os.geteuid())))
' "$h215_bash" || exit 1
for h215_tool in bash python3 script getfacl setfacl fuser stat sha256sum git uname cat id wc systemd-detect-virt timeout; do
  h215_record "N2-type-$h215_tool" 10 0 "$h215_bash" --noprofile --norc -c '
test "$(type -t "$1")" = file || exit 1
p=$(command -v "$1") || exit 1
case "$p" in /*) ;; *) exit 1 ;; esac
test -f "$p" && test -x "$p" || exit 1
printf "%s\n" "$p"
' _ "$h215_tool" || exit 1
done
h215_record N2-bash-version 10 0 "$h215_bash" --version || exit 1
h215_record N2-python-version 10 0 "$h215_python" --version || exit 1
h215_record N2-script-help 10 0 script --help || exit 1
h215_record N2-getfacl-help 10 0 getfacl --help || exit 1
h215_record N2-setfacl-help 10 0 setfacl --help || exit 1
h215_record N2-fuser-help 10 0,1 fuser -h || exit 1
h215_record N2-stat-help 10 0 stat --help || exit 1
h215_record N2-sha-help 10 0 sha256sum --help || exit 1
h215_record N2-timeout-help 10 0 timeout --help || exit 1
```

Compare actual interpreter paths between terminals. Inspect native supported
options: `script --quiet --flush --return --echo never --log-out --command`,
documented `SHELL` selection; numeric/absolute ACL output, modify/restore;
`fuser -v`; stat formats; SHA-256; timeout foreground/kill-after. Review Git,
uname, cat, id and wc interfaces used here too. Python supplies directory/copy/
capacity operations from its standard library. Existing coreutils `timeout`
bounds harmless logger/ACL preparation, not scanner timings. Missing tools or
unsupported options mean NO-GO, not installation/substitution. Help and Bash
syntax do not qualify runtime logger behavior.

## Phase N3 — Private evidence custody

Before any custody preparation, both terminals repeat the same read-only root
and Git identity check. A mismatch stops before directory or copy creation.

~~~bash
h215_record N3-root 30 0 "$h215_python" -B -c "$h215_repo_check" "$h215_repo" || exit 1
~~~

After successful N0–N2 review, T1 chooses a new campaign ID. No collisions or
automatically generated retries. T2 does **not** execute creation.

```bash
read -r -t 120 -p 'New approved campaign ID: ' h215_campaign || exit 1
[[ "$h215_campaign" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || exit 1
h215_record N3-ignored-path 10 0 git check-ignore -- \
  ".local/qualification/m8-3/wp2-a3-r1/$h215_campaign/R1-A01/" || exit 1
read -r -d '' h215_custody <<'PYCUSTODY' || [[ -n ${h215_custody:-} ]] || exit 1
import hashlib,json,os,re,stat,sys
from pathlib import Path
repo,campaign,d2,s2=sys.argv[1:];uid=os.geteuid()
assert uid!=0 and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,47}",campaign)
os.umask(0o077);flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
def walk(path):
 assert path.startswith("/")
 fd=os.open("/",flags)
 for name in Path(path).parts[1:]:
  assert name not in (".","..")
  nxt=os.open(name,flags,dir_fd=fd);os.close(fd);fd=nxt
  st=os.fstat(fd);assert st.st_uid in (0,uid) and not stat.S_IMODE(st.st_mode)&0o022
 return fd
def private(parent,name,new=False):
 try:os.mkdir(name,0o700,dir_fd=parent)
 except FileExistsError:
  if new:raise
 fd=os.open(name,flags,dir_fd=parent);st=os.fstat(fd)
 assert st.st_uid==uid and stat.S_IMODE(st.st_mode)==0o700
 return fd
def put(fd,name,data):
 out=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=fd)
 with os.fdopen(out,"wb") as f:
  f.write(data);f.flush();os.fsync(f.fileno())
  st=os.fstat(f.fileno());assert st.st_uid==uid and stat.S_IMODE(st.st_mode)==0o600
 src=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
 with os.fdopen(src,"rb") as f:assert f.read(len(data)+1)==data
fd=walk(repo);s=os.fstatvfs(fd);assert s.f_bavail*s.f_frsize>=64*1024*1024
for name in (".local","qualification","m8-3","wp2-a3-r1"):
 nxt=private(fd,name);os.close(fd);fd=nxt
nxt=private(fd,campaign,new=True);os.close(fd);fd=nxt
nxt=private(fd,"R1-A01",new=True);os.close(fd);fd=nxt
for name in ("readiness-T1","readiness-T2"):
 child=private(fd,name,new=True);os.close(child)
rows=[]
for path,name,digest,size in [(d2,"ds2208_a3_2.py","cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d",141372),
 (s2,"synthetic-tests.txt","4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785",14227)]:
 parent=walk(str(Path(path).parent))
 src=os.open(Path(path).name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=parent);os.close(parent)
 with os.fdopen(src,"rb") as f:
  assert stat.S_ISREG(os.fstat(f.fileno()).st_mode);data=f.read(1024*1024+1)
 assert len(data)==size and hashlib.sha256(data).hexdigest()==digest
 put(fd,name,data);rows.append(dict(path=name,bytes=size,sha256=digest))
s=os.fstatvfs(fd);assert s.f_bavail*s.f_frsize>=64*1024*1024
meta=dict(artifact_class="preparation",attempt="R1-A01",attempt_declared=False,repo=repo,campaign=campaign,
 files=rows,free_bytes=s.f_bavail*s.f_frsize,directory_identity=[os.fstat(fd).st_dev,os.fstat(fd).st_ino])
put(fd,"custody.json",(json.dumps(meta,sort_keys=True)+"\n").encode());os.close(fd)
print(json.dumps(meta,sort_keys=True))
PYCUSTODY
h215_record N3-custody 20 0 "$h215_python" -B -c "$h215_custody" \
  "$h215_repo" "$h215_campaign" "$HOME/Scripts/a3-2/ds2208_a3_2.py" "$HOME/Scripts/a3-2/synthetic-tests.txt" || exit 1
h215_attempt_dir="$h215_repo/.local/qualification/m8-3/wp2-a3-r1/$h215_campaign/R1-A01"
```

Custody creation does not declare an attempt or consume allowance. Existing
unsafe/nonprivate ancestry, collision, low capacity or partial failure stops;
do not chmod existing parents, delete evidence or pick another target for green.
T2 transcribes the same campaign ID, then verifies the custody identity and
copied bytes before writing any evidence. Run this block only in T2:

~~~bash
read -r -t 120 -p 'T1 verified campaign ID: ' h215_campaign || exit 1
[[ "$h215_campaign" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || exit 1
h215_attempt_dir="$h215_repo/.local/qualification/m8-3/wp2-a3-r1/$h215_campaign/R1-A01"
h215_record N3-path-verification 10 0 "$h215_python" -B -c '
import hashlib,json,os,stat,sys
from pathlib import Path
p=Path(sys.argv[1]);uid=os.geteuid()
for q in [p,*p.parents]:
 s=q.lstat();assert stat.S_ISDIR(s.st_mode) and s.st_uid in (0,uid)
 assert not stat.S_IMODE(s.st_mode)&0o022
assert stat.S_IMODE(p.stat().st_mode)==0o700 and p.stat().st_uid==uid
m=json.loads((p/"custody.json").read_bytes())
assert m["campaign"]==sys.argv[2] and m["attempt"]=="R1-A01" and m["attempt_declared"] is False
assert m["directory_identity"]==[p.stat().st_dev,p.stat().st_ino]
for name,size,digest in [("ds2208_a3_2.py",141372,"cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d"),
 ("synthetic-tests.txt",14227,"4e7639d4f9a7bf3311f4eda81b395b50aae8bc60397dff3aba37796bb3dbd785")]:
 f=p/name;s=f.lstat();assert stat.S_ISREG(s.st_mode) and s.st_uid==uid and stat.S_IMODE(s.st_mode)==0o600
 b=f.read_bytes();assert len(b)==size and hashlib.sha256(b).hexdigest()==digest
print("T2_CUSTODY_AND_APPROVED_COPIES_VERIFIED")
' "$h215_attempt_dir" "$h215_campaign" || exit 1
~~~

Both terminals load the following flush code and persist their original buffers:

```bash
read -r -d '' h215_flush_code <<'PYFLUSH' || [[ -n ${h215_flush_code:-} ]] || exit 1
import base64,hashlib,json,os,stat,sys
from pathlib import Path
folder,role=sys.argv[1:];uid=os.geteuid()
assert folder.startswith("/") and role in ("T1","T2")
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC;fd=os.open("/",flags)
for name in Path(folder).parts[1:]:
 assert name not in (".","..")
 nxt=os.open(name,flags,dir_fd=fd);os.close(fd);fd=nxt
 st=os.fstat(fd);assert st.st_uid in (0,uid) and not stat.S_IMODE(st.st_mode)&0o022
assert os.fstat(fd).st_uid==uid and stat.S_IMODE(os.fstat(fd).st_mode)==0o700
def put(name,data):
 out=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=fd)
 with os.fdopen(out,"wb") as f:
  f.write(data);f.flush();os.fsync(f.fileno())
  assert stat.S_IMODE(os.fstat(f.fileno()).st_mode)==0o600
 src=os.open(name,os.O_RDONLY|os.O_NOFOLLOW,dir_fd=fd)
 with os.fdopen(src,"rb") as f:assert f.read(len(data)+1)==data
for i,line in enumerate(sys.stdin):
 assert i<128 and len(line)<=98305
 r=json.loads(line);assert r["role"]==role
 label=r["label"];assert label and all(c.isascii() and (c.isalnum() or c in "-_") for c in label)
 raw=base64.b64decode(r["output_b64"],validate=True)
 assert len(raw)==r["output_bytes"] and hashlib.sha256(raw).hexdigest()==r["output_sha256"]
 put(label+".json",line.encode());put(label+".out",raw)
 put(label+".exit",(str(r["returncode"])+"\n").encode())
os.close(fd)
PYFLUSH
h215_flush() {
  [[ -n "$h215_sink" && ${#h215_records[@]} -gt 0 ]] || return 1
  printf '%s\n' "${h215_records[@]}" | "$h215_python" -B -c "$h215_flush_code" "$h215_sink" "$h215_role" || return 1
  h215_records=()
}
h215_sink="$h215_attempt_dir/readiness-$h215_role"
h215_flush || exit 1
```

In T1 save capture source, then create the helpers in the subsequent phases.
Noclobber must remain enabled. All outputs are new owner-only files in trusted
private directories; never use `>|`, force, append, existing targets or symlinks.
Failure preserves partial files and stops. Verify helpers in T2; no source
substitution is permitted. Set/export the same verified attempt variables there.

```bash
[[ ! -e "$h215_attempt_dir/capture-source.py" && ! -L "$h215_attempt_dir/capture-source.py" ]] || exit 1
printf '%s\n' "$h215_collector" > "$h215_attempt_dir/capture-source.py" || exit 1
```

In **both** terminals set/export these already verified paths; T2 must not
run T1's source-file creation command:

```bash
h215_diag="$h215_attempt_dir/ds2208_a3_2.py"
export h215_attempt_dir h215_python h215_bash h215_diag
```

Keep physical `owner.log`, `fresh.log`, their exit files and timing/probe targets
absent. Readiness artifacts cannot masquerade as physical experiment outputs.

## Phase N4 — Native PTY/logger qualification

T1 creates this harmless helper in the private attempt directory, using
noclobber. T2 uses the same verified helper after T1 finishes creating it.
It reads only its own logger PTY, never a scanner. The only input is an empty
Enter; do not type a fixture, password or other text.

~~~bash
cat > "$h215_attempt_dir/logger-probe.py" <<'PYLOGGER' || exit 1
import json,os,select,signal,sys,termios
def expired(signum,frame):raise TimeoutError()
signal.signal(signal.SIGALRM,expired);signal.alarm(15)
try:
 assert os.isatty(0) and os.isatty(1)
 attrs=termios.tcgetattr(0)
 assert attrs[3]&termios.ICANON and not attrs[3]&termios.ECHO
 print(json.dumps(dict(event="LOGGER_READY",stdin_tty=True,stdout_tty=True,
                       canonical=True,echo=False)),flush=True)
 print("Press EMPTY ENTER once within ten seconds.",flush=True)
 assert select.select([0],[],[],10)[0]
 assert os.read(0,2)==b"\n"
 print("LOGGER_EMPTY_ENTER_ACCEPTED",flush=True)
except (AssertionError,OSError,TimeoutError,KeyboardInterrupt):
 print("LOGGER_CHECK_FAILED",flush=True);sys.exit(90)
sys.exit(23)
PYLOGGER
~~~

Run the next block independently in T1/T2, with their existing role variables.
The freshly and exclusively created private subdirectory plus absent target
protects the logger: Bash noclobber alone does **not** protect a file opened
by script. There must be one writer per role, no symlink or collision.
Do not pipe or redirect stdin. The wrapper's selected Bash must report the
same validated pathname. Native documentation must confirm SHELL selection;
help inspection alone is insufficient.

~~~bash
h215_logger_dir="$h215_attempt_dir/logger-$h215_role"
h215_record N4-directory 10 0 "$h215_python" -B -c '
import os,stat,sys
p=sys.argv[1];os.mkdir(p,0o700)
s=os.lstat(p);assert stat.S_ISDIR(s.st_mode) and s.st_uid==os.geteuid()
assert stat.S_IMODE(s.st_mode)==0o700
print("EXCLUSIVE_PRIVATE_LOGGER_DIRECTORY")
' "$h215_logger_dir" || exit 1
[[ ! -e "$h215_logger_dir/output.raw" && ! -L "$h215_logger_dir/output.raw" ]] || exit 1
h215_logger_args=(script --quiet --flush --return --echo never
  --log-out "$h215_logger_dir/output.raw"
  --command 'test -n "$BASH_VERSION" && test "$BASH" = "$h215_bash" || exit 91; printf "SELECTED_BASH=%s\n" "$BASH"; exec "$h215_python" -B "$h215_attempt_dir/logger-probe.py"')
printf '%q ' "SHELL=$h215_bash" timeout --foreground --kill-after=2s 20s \
  "${h215_logger_args[@]}" > "$h215_logger_dir/command.txt" || exit 1
if SHELL="$h215_bash" timeout --foreground --kill-after=2s 20s "${h215_logger_args[@]}"; then
  h215_logger_rc=0
else
  h215_logger_rc=$?
fi
printf '%s\n' "$h215_logger_rc" > "$h215_logger_dir/exit.txt" || exit 1
[[ "$h215_logger_rc" == 23 ]] || exit 1
h215_record N4-inspect 10 0 "$h215_python" -B -c '
import hashlib,json,os,stat,sys
from pathlib import Path
p=Path(sys.argv[1]);s=p.lstat()
assert stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and stat.S_IMODE(s.st_mode)==0o600
b=p.read_bytes();assert len(b)<=65536
assert b"SELECTED_BASH="+os.fsencode(sys.argv[2]) in b
assert b"LOGGER_READY" in b and b"LOGGER_EMPTY_ENTER_ACCEPTED" in b
assert b"LOGGER_CHECK_FAILED" not in b
print(json.dumps(dict(path=str(p),bytes=len(b),sha256=hashlib.sha256(b).hexdigest(),
                     mode=oct(stat.S_IMODE(s.st_mode)),child_exit=23)))
' "$h215_logger_dir/output.raw" "$h215_bash" || exit 1
~~~

Expected: canonical interactive PTY, echo off, selected Bash, one empty Enter
accepted, child status 23 preserved through --return, ordinary termination,
one output-only raw transcript with mode 0600. Retain its original CR/LF bytes.
No input/combined logger flags are permitted. The harmless command's stdin
read proves interactivity; empty input contains no secret and is not a scanner
fixture. Inspect captured argv and native behavior in both terminals.
Unexpected prompt/echo, wrong shell/status, timeout (including 124/137), missing
output, inability to terminate or uncertain permissions means STOP / A-07
NO-GO. No scanner source is executed and reserved physical logs stay absent.

## Phase N5 — Passive original-A scanner identity

T1 creates the following allowlisted passive inspector. It opens selected sysfs
attributes only; it never opens a character endpoint. Bounds are explicit:
4,096 entries per top-level inventory, 256 USB children, 32 ancestors, 64-byte
attributes and 4,096-byte allowlisted uevent reads. VID/PID reads on USB entries
are only to distinguish the selected profile. No serial or arbitrary attributes,
unrelated device dumps or udev environments are read.

~~~bash
cat > "$h215_attempt_dir/passive-A.py" <<'PYPASSIVE' || exit 1
import json,os,re,stat,sys
from pathlib import Path
def entries(p,limit):
 with os.scandir(p) as it:
  result=[]
  for item in it:
   if len(result)>=limit:raise ValueError("inventory_bound")
   result.append(Path(item.path))
 return result
def attr(p):
 with p.open("rb") as f:b=f.read(65)
 if len(b)>64:raise ValueError("attribute_bound")
 return b.decode("ascii").strip()
def obj(p):
 s=p.stat();return [s.st_dev,s.st_ino]
def kind(p,wanted):
 subsystem=p/"subsystem";event=p/"uevent"
 if not subsystem.is_symlink() or subsystem.resolve(strict=True).name!="usb":return False
 with event.open("rb") as f:b=f.read(4097)
 if len(b)>4096:raise ValueError("uevent_bound")
 return ("DEVTYPE="+wanted) in b.decode("ascii").splitlines()
def nearest(p,wanted):
 for _ in range(32):
  if kind(p,wanted):return p
  if p.parent==p:break
  p=p.parent
 raise ValueError("ancestor_not_found")
def inspect():
 matches=[]
 for p in entries("/sys/bus/usb/devices",4096):
  if not (p/"idVendor").exists() or not (p/"idProduct").exists():continue
  if attr(p/"idVendor")=="05e0" and attr(p/"idProduct")=="1701":
   matches.append(p.resolve(strict=True))
 if len(matches)!=1:raise ValueError("usb_ambiguity")
 usb=matches[0];interfaces=[]
 for p in entries(usb,256):
  if not (p/"bInterfaceNumber").exists():continue
  q=p.resolve(strict=True)
  if not q.parent.samefile(usb) or not kind(q,"usb_interface"):raise ValueError("interface_parent")
  profile=[attr(q/x) for x in ("bInterfaceClass","bInterfaceSubClass","bInterfaceProtocol")]
  driver=(q/"driver").resolve(strict=True).name
  if driver!="cdc_acm":raise ValueError("driver")
  interfaces.append(dict(path=str(q),number=attr(q/"bInterfaceNumber"),profile=profile,
                         driver=driver,object=obj(q)))
 if len(interfaces)!=2 or sorted(x["profile"] for x in interfaces)!=[["02","02","01"],["0a","00","00"]]:
  raise ValueError("interface_profile")
 endpoints=[]
 for p in entries("/sys/class/tty",4096):
  if not re.fullmatch(r"ttyACM[0-9]{1,8}",p.name):continue
  tty=p.resolve(strict=True);interface=nearest(tty,"usb_interface")
  parent=nearest(interface.parent,"usb_device")
  if not parent.samefile(usb):continue
  if not any(Path(x["path"]).samefile(interface) and x["profile"]==["02","02","01"] for x in interfaces):
   raise ValueError("tty_interface")
  node=Path("/dev")/p.name;s=node.lstat()
  if not stat.S_ISCHR(s.st_mode) or node.is_symlink():raise ValueError("node_type")
  major,minor=os.major(s.st_rdev),os.minor(s.st_rdev)
  if attr(p/"dev")!=f"{major}:{minor}":raise ValueError("character_number")
  if not Path(f"/sys/dev/char/{major}:{minor}").samefile(tty):raise ValueError("character_sysfs")
  identity=dict(node=str(node),usb=str(usb),interface=str(interface),tty=str(tty),
    vid="05e0",pid="1701",driver="cdc_acm",rdev=f"{major}:{minor}",
    bus=attr(usb/"busnum"),address=attr(usb/"devnum"),
    interface_number=attr(interface/"bInterfaceNumber"),node_fs=s.st_dev,node_inode=s.st_ino,
    usb_object=obj(usb),interface_object=obj(interface),tty_object=obj(tty))
  endpoints.append(dict(identity=identity,interfaces=sorted(interfaces,key=lambda x:x["number"]),
    node_mode=oct(stat.S_IMODE(s.st_mode)),node_uid=s.st_uid,node_gid=s.st_gid,
    effective_read=os.access(node,os.R_OK,effective_ids=True),
    effective_write=os.access(node,os.W_OK,effective_ids=True)))
 if len(endpoints)!=1:raise ValueError("endpoint_ambiguity")
 return endpoints[0]
try:
 first=inspect();second=inspect()
 if first!=second:raise ValueError("identity_changed")
 print(json.dumps(first,sort_keys=True))
except (OSError,ValueError) as e:
 print(json.dumps(dict(event="PASSIVE_IDENTITY_UNAVAILABLE",
                       errno=getattr(e,"errno",None))),flush=True)
 sys.exit(2)
PYPASSIVE
h215_record N5-identity 15 0 "$h215_python" -B "$h215_attempt_dir/passive-A.py" || exit 1
read -r -t 120 -p 'Verified original-A /dev/ttyACM name: ' h215_original_node || exit 1
[[ "$h215_original_node" =~ ^/dev/ttyACM[0-9]{1,8}$ ]] || exit 1
test -c "$h215_original_node" && test ! -L "$h215_original_node" || exit 1
h215_record N5-selected 10 0 "$h215_python" -B -c '
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_bytes())
assert r["identity"]["node"]==sys.argv[2]
print("OPERATOR_SELECTION_MATCHES_PASSIVE_MAPPING")
' "$h215_sink/N5-identity.out" "$h215_original_node" || exit 1
h215_record N5-users 10 0,1 fuser -v -- "$h215_original_node" || exit 1
export h215_original_node
~~~

Review actual bus/address, canonical USB/interface/TTY relationships,
communications/data profiles, character number, node filesystem/inode and
sysfs object metadata. Topology follows from actual USB path, not a fixed
name or hardcoded ancestry depth. Human confirms the intended physical unit.
No matching field proves immutable physical identity or held continuity.
Two equal snapshots only corroborate a momentary observation.

Review fuser status **and** output/visibility; status 1 is not automatically
proof of no users. Unexplained users, insufficient visibility or a stopped
passive check means NO-GO. Do not kill services, use privileged process inspection
or open the scanner to resolve uncertainty. Stop if any scanner state changes
or unexpected input is observed.

## Phase N6 — Original-A diagnostic preflight

Only T1 performs the approved preflight --device, using independently selected
A and the attempt-local exact D2 bytes. There is no scanner open in this mode.
No self-test, acquisition, cleanup-check, hold, fresh or overlap mode is allowed.

~~~bash
h215_record N6-source 10 0 "$h215_python" -B -c '
import hashlib,sys
from pathlib import Path
b=Path(sys.argv[1]).read_bytes()
assert len(b)==141372 and hashlib.sha256(b).hexdigest()=="cfa4ae38c162eec5a2f048ca2c95c8a0c60da6dfc5f409b6d6c425ccd17d3d7d"
print("APPROVED_D2_BYTES_VERIFIED")
' "$h215_diag" || exit 1
h215_record N6-preflight 180 0 "$h215_python" -B "$h215_diag" preflight --device "$h215_original_node" || exit 1
cat > "$h215_attempt_dir/compare-A.py" <<'PYCOMPARE' || exit 1
import hashlib,json,re,sys
from pathlib import Path
kind,left,right=sys.argv[1:]
passive=json.loads(Path(left).read_bytes());a=passive["identity"]
if kind=="passive":b=json.loads(Path(right).read_bytes())["identity"]
elif kind=="preflight":
 raw=Path(right).read_bytes();capture=json.loads(Path(right).with_suffix(".json").read_bytes())
 assert capture["complete"] is True and capture["returncode"]==0
 assert capture["output_bytes"]==len(raw) and capture["output_sha256"]==hashlib.sha256(raw).hexdigest()
 events=[json.loads(line) for line in raw.splitlines()]
 phases=[x for x in events if x.get("event")=="PHASE"]
 preflights=[x for x in events if x.get("event")=="preflight"]
 exits=[x for x in events if x.get("event")=="DIAGNOSTIC_EXIT"]
 assert len(phases)==len(preflights)==len(exits)==1
 assert phases[0]["phase"]=="preflight" and events[-1] is exits[0]
 assert events.index(phases[0])<events.index(preflights[0])<events.index(exits[0])
 assert all(x["process_id"]==capture["child_pid"] for x in events)
 assert exits[0]["phase_completed"] is True and exits[0]["exit_code"]==0
 assert exits[0]["cleanup_warning"] is False
 assert exits[0]["physical_qualification_pass_not_automatically_inferred"] is True
 p=preflights[0];b=p["snapshot"]
 assert p["access_is_advisory"] is True and p["continuity_proof"] is False
 assert type(p["mode"]) is str and type(passive["node_mode"]) is str
 assert int(p["mode"],8)==int(passive["node_mode"],8)
 for outer,independent in (("uid","node_uid"),("gid","node_gid")):
  assert type(p[outer]) is int and type(passive[independent]) is int
  assert p[outer]==passive[independent]
 for outer,independent in (("read","effective_read"),("write","effective_write")):
  assert type(p["effective_access"][outer]) is bool and type(passive[independent]) is bool
  assert p["effective_access"][outer] is passive[independent]
else:raise ValueError("comparison_kind")
paths=("node","usb","interface","tty")
labels=("vid","pid","driver")
decimal=("bus","address")
numbers=("node_fs","node_inode")
objects=("usb_object","interface_object","tty_object")
required=set(paths+labels+decimal+numbers+objects+("rdev","interface_number"))
assert set(a)==set(b)==required,"NO_GO: missing or unexpected identity fields"
for source in (a,b):
 for field in paths+labels:
  assert type(source[field]) is str and 1<=len(source[field])<=1024
 assert source["vid"]=="05e0" and source["pid"]=="1701" and source["driver"]=="cdc_acm"
 for field in decimal:
  assert type(source[field]) is str and re.fullmatch(r"[0-9]{1,5}",source[field])
 assert type(source["rdev"]) is str and re.fullmatch(r"[0-9]{1,10}:[0-9]{1,10}",source["rdev"])
 assert type(source["interface_number"]) is str and re.fullmatch(r"[0-9a-fA-F]{2}",source["interface_number"])
 for field in numbers:
  assert type(source[field]) is int and source[field]>=0
 for field in objects:
  assert type(source[field]) is list and len(source[field])==2
  assert all(type(n) is int and n>=0 for n in source[field])
for field in paths+labels+numbers+objects:
 assert a[field]==b[field],"NO_GO: identity correspondence mismatch: "+field
for field in decimal:
 assert int(a[field],10)==int(b[field],10),"NO_GO: enumeration correspondence mismatch: "+field
assert tuple(map(int,a["rdev"].split(":")))==tuple(map(int,b["rdev"].split(":"))),"NO_GO: character identity mismatch"
assert int(a["interface_number"],16)==int(b["interface_number"],16),"NO_GO: interface number mismatch"
print("EXACT_A_IDENTITY_MATCH")
PYCOMPARE
h215_record N6-compare 10 0 "$h215_python" -B "$h215_attempt_dir/compare-A.py" preflight \
  "$h215_sink/N5-identity.out" "$h215_sink/N6-preflight.out" || exit 1
~~~

The collector refuses existing N6-preflight.json/.out/.exit targets and
preserves actual output/return status. Do not substitute a copied summary.
Require agreement with N5; a successful diagnostic exit alone is insufficient.
Effective access in preflight is advisory. Success proves neither durable
attachment continuity nor FD ownership, Core authority or release for execution.

Static schema reference: approved A3.2 resolve_once supplies all 16 snapshot
fields listed by the comparison helper; preflight emits the lowercase event
name and wraps that dictionary under snapshot. Its outer mode, uid, gid and
effective_access correspond respectively to passive node_mode, node_uid,
node_gid and effective_read/effective_write. Access may legitimately be false
in this phase: the CLI calls preflight with require_access=False. N7 separately
requires current effective R/W. A successful preflight requires both captured
process status 0 and the attributable DIAGNOSTIC_EXIT with phase_completed=true,
exit_code=0 and no cleanup warning. A zero exit alone is insufficient.

The comparison checks every required canonical path, USB/profile/driver label,
enumeration number, communications-interface number, character major/minor,
node filesystem/inode and USB/interface/TTY object pair. Numeric encodings are
compared by their decimal/hexadecimal meaning. Missing, malformed, contradictory
or unassignable required fields are NO-GO; no diagnostic value populates the
independently collected passive snapshot. The passive inspector remains unchanged.
Its additional data-interface object evidence has no corresponding D2 output
field: retain it as independently observed supporting evidence for review, not
as a claimed cross-source inode match. Both inspectors enforce the two-interface
profile; neither observations nor equal object metadata eliminate sampling races.

## Phase N7 — Original-A access and ACL preparation

T1 captures A's own full numeric ACL and node key, even if no grant is needed.
These are not B's future backup. Continue only while A's full physical
correlation remains stable; a pathname/key alone is insufficient.

~~~bash
h215_node="$h215_original_node"
h215_record N7-before 15 0 "$h215_python" -B "$h215_attempt_dir/passive-A.py" || exit 1
h215_record N7-before-compare 10 0 "$h215_python" -B "$h215_attempt_dir/compare-A.py" passive \
  "$h215_sink/N5-identity.out" "$h215_sink/N7-before.out" || exit 1
h215_record N7-acl-before 10 0 getfacl --absolute-names --numeric -- "$h215_node" || exit 1
h215_record N7-key-before 10 0 stat -c '%d:%i:%t:%T' -- "$h215_node" || exit 1
h215_acl_before="$h215_sink/N7-acl-before.out"
h215_node_key_file="$h215_sink/N7-key-before.out"
~~~

If N7-before reports effective read and write access, record **NO ACL CHANGE
NEEDED** in the final attestation and skip grant/restoration. Do not invoke
sudo unnecessarily. Otherwise the following is **human-only**, under Decision B,
using the [adopted ACL guards](h2-15-r1-execution-plan.md#device-scoped-acl-procedure--future-human-operations-only).
The owner reviews selected identity, ACL and proposed operation before each
privileged command. Codex does not invoke it.

Before a needed grant, validate the backup and obtain direct approval. Do not
paste the grant block for an already accessible device.

~~~bash
h215_record N7-sudo-tool 10 0 "$h215_bash" --noprofile --norc -c '
test "$(type -t sudo)" = file || exit 1
p=$(command -v sudo) || exit 1
case "$p" in /*) ;; *) exit 1 ;; esac
test -f "$p" && test -x "$p" || exit 1
printf "%s\n" "$p"
' || exit 1
h215_record N7-backup-check 10 0 "$h215_python" -B -c '
import hashlib,json,sys
from pathlib import Path
folder=Path(sys.argv[1]);node=sys.argv[2]
for name in ("N7-acl-before","N7-key-before"):
 b=(folder/(name+".out")).read_bytes();r=json.loads((folder/(name+".json")).read_bytes())
 assert r["complete"] and r["returncode"]==0 and hashlib.sha256(b).hexdigest()==r["output_sha256"]
acl=(folder/"N7-acl-before.out").read_text()
assert [x for x in acl.splitlines() if x.startswith("# file: ")]==["# file: "+node]
print("ORIGINAL_A_BACKUP_INTEGRITY_VERIFIED")
' "$h215_sink" "$h215_node" || exit 1
read -r -t 120 -p 'Approve this selected-A temporary ACL grant? Type GRANT-A: ' h215_acl_approval || exit 1
[[ "$h215_acl_approval" == GRANT-A ]] || exit 1
h215_record N7-pregrant 15 0 "$h215_python" -B "$h215_attempt_dir/passive-A.py" || exit 1
h215_record N7-pregrant-compare 10 0 "$h215_python" -B "$h215_attempt_dir/compare-A.py" passive \
  "$h215_sink/N5-identity.out" "$h215_sink/N7-pregrant.out" || exit 1
exec {h215_acl_out}> "$h215_sink/N7-grant.out" || exit 1
exec {h215_acl_exit}> "$h215_sink/N7-grant.exit" || exit 1
if (
  test -c "$h215_node" && test ! -L "$h215_node" &&
  test "$(stat -c '%d:%i:%t:%T' -- "$h215_node")" = "$(cat "$h215_node_key_file")" &&
  timeout --foreground --kill-after=2s 60s sudo setfacl -m "u:$(id -u):rw" -- "$h215_node"
) >&"$h215_acl_out" 2>&1; then
  h215_acl_rc=0
else
  h215_acl_rc=$?
fi
printf '%s\n' "$h215_acl_rc" >&"$h215_acl_exit" || exit 1
exec {h215_acl_out}>&-
exec {h215_acl_exit}>&-
[[ "$h215_acl_rc" == 0 ]] || exit 1
h215_record N7-acl-after 10 0 getfacl --absolute-names --numeric -- "$h215_node" || exit 1
h215_record N7-after 15 0 "$h215_python" -B "$h215_attempt_dir/passive-A.py" || exit 1
h215_record N7-after-compare 10 0 "$h215_python" -B "$h215_attempt_dir/compare-A.py" passive \
  "$h215_sink/N5-identity.out" "$h215_sink/N7-after.out" || exit 1
h215_record N7-after-access 10 0 "$h215_python" -B -c '
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_bytes())
assert r["effective_read"] and r["effective_write"]
print("CURRENT_A_EFFECTIVE_RW_CONFIRMED")
' "$h215_sink/N7-after.out" || exit 1
~~~

This is the existing selected-device setfacl procedure with bounded supervision
and protected output files, not broader privilege. Capture sudo's output, never
its input/password; it may prompt through the native controlling terminal.
Missing sudo/support, failed guard, timeout, uncertain completion or changed
identity means stop/review, not retry. A timeout cannot prove an ACL was unchanged:
preserve facts and assess safe cleanup. Do not run the diagnostic as root.

If not proceeding to a separately approved Decision C in the same controlled
session, assess safe restoration of a temporary grant. This handoff grants no C.
After review, the operator explicitly approves restoration; check full current A
identity again after that approval, not just a stale pathname. Any known
replacement prohibits restoring A's backup to the new node.

~~~bash
read -r -t 120 -p 'Approve identity-checked original-A ACL restoration? Type RESTORE-A: ' h215_acl_restore || exit 1
[[ "$h215_acl_restore" == RESTORE-A ]] || exit 1
h215_record N7-prerestore 15 0 "$h215_python" -B "$h215_attempt_dir/passive-A.py" || exit 1
h215_record N7-prerestore-compare 10 0 "$h215_python" -B "$h215_attempt_dir/compare-A.py" passive \
  "$h215_sink/N5-identity.out" "$h215_sink/N7-prerestore.out" || exit 1
h215_record N7-restore-backup-check 10 0 "$h215_python" -B -c '
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]);b=p.read_bytes();r=json.loads(Path(sys.argv[2]).read_bytes())
assert r["complete"] and r["returncode"]==0 and hashlib.sha256(b).hexdigest()==r["output_sha256"]
assert [x for x in b.decode().splitlines() if x.startswith("# file: ")]==["# file: "+sys.argv[3]]
print("RESTORATION_BACKUP_UNCHANGED")
' "$h215_acl_before" "$h215_sink/N7-acl-before.json" "$h215_node" || exit 1
exec {h215_acl_out}> "$h215_sink/N7-restore.out" || exit 1
exec {h215_acl_exit}> "$h215_sink/N7-restore.exit" || exit 1
if (
  test -c "$h215_node" && test ! -L "$h215_node" &&
  test "$(stat -c '%d:%i:%t:%T' -- "$h215_node")" = "$(cat "$h215_node_key_file")" &&
  timeout --foreground --kill-after=2s 60s sudo setfacl --restore="$h215_acl_before"
) >&"$h215_acl_out" 2>&1; then
  h215_acl_rc=0
else
  h215_acl_rc=$?
fi
printf '%s\n' "$h215_acl_rc" >&"$h215_acl_exit" || exit 1
exec {h215_acl_out}>&-
exec {h215_acl_exit}>&-
[[ "$h215_acl_rc" == 0 ]] || exit 1
h215_record N7-acl-restored 10 0 getfacl --absolute-names --numeric -- "$h215_node" || exit 1
h215_record N7-restored 15 0 "$h215_python" -B "$h215_attempt_dir/passive-A.py" || exit 1
h215_record N7-restored-compare 10 0 "$h215_python" -B "$h215_attempt_dir/compare-A.py" passive \
  "$h215_sink/N5-identity.out" "$h215_sink/N7-restored.out" || exit 1
h215_record N7-restored-acl-check 10 0 "$h215_python" -B -c '
import sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes()==Path(sys.argv[2]).read_bytes()
print("ORIGINAL_A_ACL_RESTORED")
' "$h215_acl_before" "$h215_sink/N7-acl-restored.out" || exit 1
~~~

Record whether a grant occurred, why, direct human approvals, both results and
restoration disposition. A disappeared original node's ACL disappears with that
object; mark restoration not applicable only with corroborated removal evidence.
Ambiguity requires review, never a pathname-based restore. Access restored before
a later execution session requires **fresh identity/access verification**; do not
carry a stale B-03 GO forward. B's future identity/ACL remain entirely separate.
No permanent group change, world access, service stop or broad policy change.

## Phase N8 — Final prelaunch readiness handoff

First compare the two preserved native contexts. T1 runs:

~~~bash
h215_record N8-terminal-compare 10 0 "$h215_python" -B -c '
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);contexts=[];metadata=[]
source_hash=hashlib.sha256((root/"capture-source.py").read_bytes()).hexdigest()
for role in ("T1","T2"):
 folder=root/("readiness-"+role)
 contexts.append(json.loads((folder/"N0-context.out").read_bytes()))
 metadata.append(json.loads((folder/"N0-context.json").read_bytes()))
 records=list(folder.glob("*.json"));assert len(records)<=128
 for p in records:
  r=json.loads(p.read_bytes())
  assert r["collector_sha256"]==source_hash and r["complete"]
  assert r["boot_sha256"]==metadata[-1]["boot_sha256"]
assert contexts[0]["boot_id"]==contexts[1]["boot_id"]
assert metadata[0]["boot_sha256"]==metadata[1]["boot_sha256"]
assert contexts[0]["tty"]!=contexts[1]["tty"]
assert metadata[0]["caller_shell_pid"]!=metadata[1]["caller_shell_pid"]
interpreters=[json.loads((root/("readiness-"+role)/"N2-interpreters.out").read_bytes()) for role in ("T1","T2")]
assert interpreters[0]["bash"]==interpreters[1]["bash"] and interpreters[0]["python"]==interpreters[1]["python"]
print("TWO_TERMINALS_SAME_BOOT_DISTINCT_SHELLS_AND_CAPTURE_SOURCE")
' "$h215_attempt_dir" || exit 1
~~~

This is corroboration, not proof against a malicious host. Human attestation
must independently identify the intended native VMware guest, direct terminal
path, physical unit and absence of sandbox/remote execution. Keep private boot
identifiers and their digests outside tracked Markdown.

Complete the following **private review template**, using actual original paths
and line/event references; all disposition cells start PENDING. This table is
not completed readiness evidence in the repository. No GO is asserted here.

- **GO:** currently applicable prerequisite supported by actual attributable
  native evidence and the required operator/reviewer judgment.
- **NO-GO:** mandatory prerequisite failed; stop before declaration.
- **PENDING:** future approval/runtime checkpoint, or work not completed yet.
- **NOT VERIFIED:** required evidence unavailable/untrusted; not a substitute GO.

| Gate | Required observation | Original evidence path (planned) | Line/event | Actual disposition | Operator attestation | Remaining prerequisite | Reviewer qualification |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A-01 | Branch/current HEAD/status, pinned qualification baseline and criteria/plan/decisions | readiness-T1/N1-*.out and .json; T2 equivalents | PENDING | PENDING | Later doc commits reviewed | Identity review | Current HEAD is not qualification baseline |
| A-02 | Original D2/S2 and verified attempt-local copies; prior 91-test provenance | N1-identities.out; custody.json; ds2208_a3_2.py; synthetic-tests.txt | PENDING | PENDING | Saved-report provenance acknowledged | Verify copies/digests/size | No new tests executed |
| A-03 | Native Fedora/Kinoite/ARM64/VMware, ordinary owner, same boot, distinct host terminals | readiness-T1/N0-*.out/.json; T2 equivalents; N8-terminal-compare.out | PENDING | PENDING | Intended Fusion/M1 guest confirmed | Boundary review | OS string alone is insufficient |
| A-04 | All required tools/options supported natively | readiness-T1/N2-*.out/.json; T2 equivalents | PENDING | PENDING | No tool substitution | Native compatibility review | Help is not runtime behavior |
| A-05 | Same validated absolute Bash and explicit SHELL selection | N2-interpreters.out; logger-T1/command.txt and output.raw; T2 equivalents | PENDING | PENDING | Both native Bash checks | Compare paths/runtime | No alias/function or inherited-shell assumption |
| A-06 | Exclusive private custody, modes, copies, capacity, no collisions | custody.json; artifact-inventory.json; N3-custody.out | PENDING | PENDING | One new approved campaign | Verify complete custody | Directory creation is preparation, not attempt declaration |
| A-07 | Both interactive PTYs, output-only/echo-off logger, child status and fixture/checkpoint rehearsal | logger-T1/output.raw and exit.txt; T2 equivalents | PENDING | PENDING | Quiet scanner, privately known fixture, rehearsal | Review both native tests | No scanner acquisition was tested |
| B-01 | Intended single USB/profile/interfaces/driver | readiness-T1/N5-identity.out | PENDING | PENDING | Intended physical unit | Fresh mapping review | No immutable identity proof |
| B-02 | Node/TTY/dev-char agreement, approved preflight, competing-user review | N5-users.out/.exit; N6-preflight.out/.exit; N6-compare.out | PENDING | PENDING | Visibility/ownership accounted for | Resolve any uncertainty | fuser absence alone is insufficient |
| B-03 | A-specific backup/current identity/effective R/W and any grant/restoration | readiness-T1/N7-*.out/.exit/.json | PENDING | PENDING | Each privileged operation and disposition | Fresh access if restored/later session | Never apply A backup to B |
| B-04 | Replacement verification/access procedure prepared; actual B remains unknown | Adopted plan Phase 4; separate future B paths, currently absent | PENDING | PENDING | Procedure understood | FRESH_PREPARATION_PERMITTED runtime checkpoint | Prelaunch review cannot verify future B identity |
| C-01 | A/B approved; explicit separate native readiness release | Decision A/B records; future C record absent | PENDING | PENDING | No C granted by this handoff | Human Decision C | No attempt declaration or owner launch |
| C-02 | Exact launch/exports/handoff preparation reviewed | Adopted plan launch templates; private rehearsal attestation | PENDING | PENDING | Two-terminal sequence understood | Actual runtime PIDs/deadline later | No historical values or deadline fabricated |
| C-03 | One operator, quiet scanner, checkpoint understanding and private fixture | Private operator attestation | PENDING | PENDING | No presentation during preparation | Runtime quiet/sync/arm checks later | Prelaunch preparation does not establish future behavior |

Paths without an explicit role directory in the template must be expanded to
the actual role's private file, not interpreted as existing root files.
B-04 prelaunch readiness concerns the procedure only: actual B preflight/access
is deferred until FRESH_PREPARATION_PERMITTED. C-02/C-03 can document completed
prelaunch preparation while retaining pending runtime observations. C-01 remains
PENDING until a separate human Decision C; this task cannot grant it.

Before archival the operator prepares a new private
operator-readiness.txt containing the completed fourteen-row assessment and
attestations, with actual UTC time, operator identity, direct-native guest/terminal
confirmation, physical-unit selection, known later documentation commit review,
saved-test provenance, private fixture/checkpoint rehearsal, ACL approvals and
disposition, remaining conditions and reviewer limitations. Do not include the
fixture itself. Treat it as an operator assessment, not machine observations.

Compose the full assessment privately before submission. The following process
holds a draft of at most 32,768 bytes in memory, displays it for the operator's
complete review, and requires an explicit preservation acknowledgement before
creating operator-readiness.txt. It has **no manual-entry deadline** and runs
directly in T1, outside the timed capture wrapper. This is prelaunch composition:
no owner deadline exists yet, and no physical timing allowance is changed.

Do not run under a logger, pipe stdin or put the prose in shell commands/history.
The helper reads only the operator's native terminal; it does not read a scanner.
Enter the complete draft, then a line containing END-ASSESSMENT. Review the
entire displayed draft, including evidence references and unresolved gates.
PRESERVE-COMPLETE acknowledges this prose only; it grants no GO or Decision C.
Cancellation, EOF, invalid text or oversized input stops without a final artifact.
There is no automatic revision/retry loop and no fabricated gate completion.

~~~bash
[[ ! -e "$h215_sink/N8-assessment-submit.exit" && ! -L "$h215_sink/N8-assessment-submit.exit" ]] || exit 1
if "$h215_python" -B -c '
import hashlib,json,os,stat,sys
from pathlib import Path
assert os.isatty(0) and os.isatty(1) and os.geteuid()!=0
root=Path(sys.argv[1]);uid=os.geteuid()
assert root.is_absolute()
flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
directory=os.open("/",flags)
for name in root.parts[1:]:
 assert name not in (".","..")
 nxt=os.open(name,flags,dir_fd=directory);os.close(directory);directory=nxt
 s=os.fstat(directory);assert s.st_uid in (0,uid) and not stat.S_IMODE(s.st_mode)&0o022
s=os.fstat(directory);assert s.st_uid==uid and stat.S_IMODE(s.st_mode)==0o700
final="operator-readiness.txt";receipt="operator-readiness.preservation.json"
for name in (final,receipt):
 try:os.stat(name,dir_fd=directory,follow_symlinks=False)
 except FileNotFoundError:pass
 else:raise SystemExit("STOP: assessment target already exists")
print("Enter completed private assessment; end with END-ASSESSMENT on its own line.",flush=True)
data=bytearray()
while True:
 line=sys.stdin.buffer.readline(32769)
 if not line:raise SystemExit("STOP: assessment submission incomplete")
 if line==b"END-ASSESSMENT\n":break
 if len(data)+len(line)>32768:raise SystemExit("STOP: assessment size limit")
 data.extend(line)
text=data.decode("utf-8")
assert text.strip() and all(c.isprintable() or c in "\n\t" for c in text)
print("\nBEGIN OPERATOR DRAFT REVIEW",flush=True)
sys.stdout.buffer.write(data);sys.stdout.flush()
print("\nEND OPERATOR DRAFT REVIEW",flush=True)
print("Review every line. Type PRESERVE-COMPLETE to preserve these exact bytes; otherwise cancel.",flush=True)
if sys.stdin.buffer.readline(65)!=b"PRESERVE-COMPLETE\n":
 raise SystemExit("STOP: draft not approved for preservation")
def preserve(name,b):
 fd=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=directory)
 with os.fdopen(fd,"w+b") as f:
  s=os.fstat(f.fileno())
  assert stat.S_ISREG(s.st_mode) and s.st_uid==uid and stat.S_IMODE(s.st_mode)==0o600
  f.write(b);f.flush();os.fsync(f.fileno());f.seek(0)
  assert f.read(len(b)+1)==b
  current=os.stat(name,dir_fd=directory,follow_symlinks=False)
  assert (current.st_dev,current.st_ino)==(s.st_dev,s.st_ino)
preserve(final,data)
result=dict(event="OPERATOR_ASSESSMENT_PRESERVED",artifact_class="operator_assessment",
 path=final,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),
 exact_readback_verified=True,operator_preservation_acknowledged=True,
 decision_c="PENDING",readiness_go_not_inferred=True,process_id=os.getpid())
preserve(receipt,(json.dumps(result,sort_keys=True)+"\n").encode())
os.fsync(directory);os.close(directory)
print(json.dumps(result,sort_keys=True),flush=True)
' "$h215_attempt_dir"; then
  h215_assessment_rc=0
else
  h215_assessment_rc=$?
fi
printf '%s\n' "$h215_assessment_rc" > "$h215_sink/N8-assessment-submit.exit" || exit 1
[[ "$h215_assessment_rc" == 0 ]] || exit 1
h215_record N8-assessment-verify 10 0 "$h215_python" -B -c '
import hashlib,json,os,stat,sys
from pathlib import Path
root=Path(sys.argv[1]);p=root/"operator-readiness.txt";receipt=root/"operator-readiness.preservation.json"
for q in (p,receipt):
 s=q.lstat();assert stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and stat.S_IMODE(s.st_mode)==0o600
with p.open("rb") as f:b=f.read(32769)
with receipt.open("rb") as f:receipt_bytes=f.read(4097)
assert len(receipt_bytes)<=4096
r=json.loads(receipt_bytes)
assert 0<len(b)<=32768 and r["bytes"]==len(b) and r["sha256"]==hashlib.sha256(b).hexdigest()
assert r["path"]==p.name and r["exact_readback_verified"] is True
assert r["operator_preservation_acknowledged"] is True and r["readiness_go_not_inferred"] is True
assert r["decision_c"]=="PENDING"
print(json.dumps(r,sort_keys=True))
' "$h215_attempt_dir" || exit 1
~~~

The final prose and its preservation receipt are owner-only, exclusively created
and verified byte-for-byte; the actual submission exit status is retained
separately. Existing evidence is never overwritten or normalized. A write,
interruption or verification failure after creation leaves any partial original
intact and stops before inventory: do not replace it or rerun to green. The
operator must seek review of that incomplete preservation. A cancelled in-memory
draft is not a preserved original or a completed readiness assessment.

Keep input free of credentials, private fixture values and raw scanner data.
Human assessment and preservation acknowledgement cannot substitute missing
command evidence, complete future runtime checks or release the experiment.

Finally T1 generates the private artifact inventory. Finish all captures in
both terminals first; do not capture more into this bundle after inventory
creation. This inventories original files, not an execution/acceptance ledger.

~~~bash
"$h215_python" -B - "$h215_attempt_dir" <<'PYINVENTORY' || exit 1
import hashlib,json,os,stat,sys
from pathlib import Path
root=Path(sys.argv[1]);uid=os.geteuid();rows=[]
for name in ("owner.log","fresh.log","owner.exit","fresh.exit","artifact-inventory.json","artifact-inventory.sha256"):
 p=root/name
 assert not p.exists() and not p.is_symlink()
def visit(folder,depth):
 assert depth<=4
 s=folder.lstat();assert stat.S_ISDIR(s.st_mode) and s.st_uid==uid and stat.S_IMODE(s.st_mode)==0o700
 with os.scandir(folder) as it:
  for item in it:
   assert len(rows)<1024
   p=Path(item.path);s=p.lstat()
   if stat.S_ISDIR(s.st_mode):visit(p,depth+1);continue
   assert stat.S_ISREG(s.st_mode) and s.st_uid==uid and stat.S_IMODE(s.st_mode)==0o600
   with p.open("rb") as f:b=f.read(1024*1024+1)
   assert len(b)<=1024*1024
   rows.append(dict(path=str(p.relative_to(root)),bytes=len(b),sha256=hashlib.sha256(b).hexdigest()))
visit(root,0)
assert any(x["path"]=="operator-readiness.txt" for x in rows)
space=os.statvfs(root);assert space.f_bavail*space.f_frsize>=64*1024*1024
meta=dict(artifact_class="prelaunch_preparation",attempt="R1-A01",attempt_declared=False,
          decision_c="PENDING",files=sorted(rows,key=lambda x:x["path"]))
data=(json.dumps(meta,sort_keys=True,indent=2)+"\n").encode()
def put(name,b):
 fd=os.open(root/name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
 with os.fdopen(fd,"wb") as f:f.write(b);f.flush();os.fsync(f.fileno())
 assert (root/name).read_bytes()==b
put("artifact-inventory.json",data)
put("artifact-inventory.sha256",(hashlib.sha256(data).hexdigest()+"  artifact-inventory.json\n").encode())
print("PRIVATE_PRELAUNCH_INVENTORY_WRITTEN_AND_VERIFIED")
PYINVENTORY
~~~

The index excludes itself and its hash sidecar to avoid self-reference. Original
files, exact bytes, sizes and hashes remain recoverable. Review both terminal
capture metadata, collector-source hash, command statuses, original raw logger
outputs and ACL results. Private evidence stays under the
[existing custody policy](evidence-index.md#evidence-custody-preservation-and-recovery);
a same-VM second copy is not off-host backup. No unapproved transfer.

## Stop conditions and independent review

Every block belongs only to its named phase and Decision B preparation.
Timeout/overflow, lost original output, source mismatch, unreviewed repository
change, non-native context, missing tools, unsafe custody, unqualified logger,
ambiguous USB/TTY identity, competing users, failed preflight, uncertain ACL,
unexpected scanner state/input or operator uncertainty means STOP at that
boundary. Do not install, repair permissions broadly, reset USB, change source,
repeat-to-green or silently substitute observations. Preserve partial evidence.
Commands cannot eliminate kernel races or prove absence of every competing open.

The reviewer must distinguish command originals, static source review, saved
synthetic evidence, human attestations and analytical inferences. Confirm all
fourteen applicable/deferred gate dispositions against their original evidence;
no aggregate GO follows from a zero exit status or completed manifest.
Missing evidence stays NOT VERIFIED or PENDING. A predeclaration readiness
NO-GO consumes no physical attempt. A demonstrated safety violation is FAIL;
an unresolved observation is INCOMPLETE / INCONCLUSIVE, never invented migration.

**STOP BEFORE R1-A01 DECLARATION AND OWNER LAUNCH.** Decisions A/B remain
APPROVED; Decision C remains PENDING. Request independent review of actual
prelaunch evidence, then a separately explicit Decision C. No R1-A02/R1-A03
authorization, new physical attempt, synchronization/acquisition scan,
verify-overlap execution or R1-C2 credit is supplied here.

The adopted physical limits remain unchanged: immutable 360-second owner
deadline shared by fresh process; disconnect 30 seconds, reconnect 45,
comparison 60, retired probe 10 seconds/50 reads, fresh acquisition 10 seconds
fully within the actual probe interval, synchronization ceiling 172 seconds,
cleanup reserve 8 seconds, unrelated diagnostic phases 180 seconds. Preparation
watchdogs do not add time to these limits.

Historical R1-C1 remains formally credited; two qualifying cycles remain, within
the proposed maximum of three additional individually authorized attempts.
H2.15 remains IN PROGRESS — NOT PASS. H2.07 remains partially substantiated;
H2.08/H2.09 retain proposed bounded PASS findings and H2.13 its accepted
PASS WITH EXPECTED CLEANUP WARNINGS. This handoff does not qualify the
production Rust parser/adapter, Racket/Core binding, bare-metal, multiple-scanner
or deployed security policy. See the unchanged [audit](audit-report.md) and
[qualification matrix](qualification-matrix.md).

## Preparation validation and limitations

Codex performed read-only repository/source/manual inspection and static checks
of this document only. No native commands in this handoff, diagnostic modes,
synthetic suite, logger, device/ACL operations or custody creation were executed.
Native helpers and PTY behavior still require human review and actual native
evidence. The prior runner-boundary NO-GO is not overturned by documentation.
Do not label this handoff as a completed readiness assessment or Decision C.
