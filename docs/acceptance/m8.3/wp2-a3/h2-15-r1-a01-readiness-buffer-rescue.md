# M8.3.3 WP2-A3 — R1-A01 Volatile Native Evidence Rescue Procedure

**CANDIDATE — HUMAN RESCUE PROCEDURE ONLY; NOT EXECUTED NATIVELY; DECISION C PENDING**

Prepared at branch feat/barcode-scanner-slice, HEAD
b423acbf2591a3372fda3a83675e2c96ffd638c1. This is a rescue of unchanged
observations from a stopped preparation, not completion of N3 or qualification.
The human must review and explicitly approve this exact runbook digest, recovery
location, two selected live terminals and permitted preservation operations
before execution. This documentation task grants no native execution permission.

## Incident and provenance

The owner reports the following for subsequent readiness session readiness_02
and proposed campaign_02. These facts are not new firsthand Codex measurements.

| Terminal | Role/count | Original sink | N3 state |
| --- | --- | --- | --- |
| Current T1 | T1; count 39; 39 array elements | Empty | STOPPED; entered=yes |
| Current T2 | T2; count 35; 35 array elements | Empty | Not entered |
| Older T2, if still open | Outside scope | Not assessed | Must not be selected |

T1's read-only ancestry check reported N3_ANCESTRY_COMPATIBLE. Its subsequent
CREATE-CUSTODY confirmation expired after 120 seconds; creation was not reached.
The timeout was a shell read, **not an original capture record**. The recovery
metadata records a new, explicit operator attestation of this event, without
inventing its timestamp, traceback or an original expiry transcript.

T2 never produced the N3 session marker. Its membership in readiness_02 requires
the operator to identify the correct window using the original opening sequence,
shell PID, TTY and captured time range. Same boot, count and collector hash do
not independently prove that membership. If uncertain, STOP; do not rescue the
older T2 or relabel its contents.

Keep both sessions open. Do not rerun N0, h215_record, h215_flush or the stopped
N3 function; do not clear arrays or change count, sink, role or N3 flags.
No original command is rerun to regenerate evidence. New rescue guards inspect
current context only; they do not become original readiness observations.

## Custody, scope and permissions

Use only this explicitly proposed recovery location, after human approval:

.local/qualification/m8-3/wp2-a3-r1/rescue_readiness_02_n3_timeout_01/

It is a sibling recovery directory, **not** campaign_02/R1-A01. Collision is STOP,
not permission to append a suffix or choose another root. campaign_02 remains
the proposed identifier associated with the stopped preparation; this rescue
neither creates that campaign nor releases/reassigns it for reuse. Its later
disposition requires review. No physical attempt allowance was consumed.

The [adopted plan](h2-15-r1-execution-plan.md#persistent-logging-and-exact-launch-templates),
[corrected N3 policy](h2-15-r1-a01-native-operator-handoff.md#phase-n3--private-evidence-custody)
and [private custody policy](evidence-index.md#evidence-custody-preservation-and-recovery)
govern storage. Existing shared ancestors may retain trusted 0755 modes:
root/operator ownership, actual directory identities, no group/other write and
no symlink traversal are checked. wp2-a3-r1 must be operator-owned 0700; T1 may
exclusively create it if absent under the reviewed rescue authorization.
A preexisting nonprivate root is STOP, never chmod. Recovery and role directories
must be new 0700 directories; files must be new 0600 regular files. Preserve the
64-MiB free-storage margin before and after preservation. No overwrite, unlink,
cleanup deletion or chmod of existing paths is permitted.

Decision B's historical preparation permission does not itself approve this
particular recovery location or prove readiness. Obtain specific human approval
for this rescue; this is not Decision C. All future command blocks below are
**instructions not executed by Codex**. Only synthetic fixtures were exercised.

## Original bytes and verification model

Each array element is the original **available JSON byte sequence**. Bash already
removed the collector's final print newline during its original command
substitution. Save that array value without adding a newline; do not fabricate
a discarded byte. NUL is used only as transport framing between elements.
Original JSON strings cannot contain a literal NUL.

Each record is saved as an exact .json file, decoded merged stdout/stderr as
.out, and a separately identified generated .status.json derivative. The original
collector merged stderr into stdout: separate streams cannot now be recovered.
CRLF, NUL and non-UTF-8 output bytes are preserved through validated base64
decoding. Existing JSON metadata, argv, PIDs, statuses, completeness/failure,
timestamps, boot references and original output hashes remain unchanged.

The verifier reads archived JSON independently of writer success messages,
rechecks decoding/hashes/order/counts/role and shell provenance, and compares
the current role's archived JSON against its still-live array. Run verification
in both terminals. Hashes and private filesystem custody do not authenticate a
malicious same-user process, host or kernel. Retain live buffers until review.

## 1 — Load the rescue program, without executing it

Use only the two identified native Fedora terminals, directly in their original
interactive Bash sessions. No Codex runner, Distrobox, SSH, logger or shell
tracing. Both load exactly the same program below. Loading changes only new
h215_rescue_* variables/functions. Do not replace h215_collector or existing
handoff helpers. The read EOF status is handled without exiting the shell.

~~~bash
h215_rescue_load() {
  [[ ! ${h215_rescue_loaded+x} ]] || return 1
  h215_rescue_loaded=yes
  read -r -d '' h215_rescue_code <<'PYRESCUE' || [[ -n ${h215_rescue_code:-} ]] || return 1
import base64,errno,hashlib,json,os,platform,re,signal,stat,sys,time
from pathlib import Path
REPO=Path("/var/home/user/Projects/grocery-pos-platform")
SUFFIX=Path(".local/qualification/m8-3/wp2-a3-r1")
RECOVERY="rescue_readiness_02_n3_timeout_01"
HANDOFF="04ce9eb095866e6f1ab1b29ae009b0a20b42a1d7f35a2115582e3e971d9700ad"
COLLECTOR="a175a753606f3b885041b94e3f8a92b7eaf0c71de939e3a47a9e1a523e02f388"
BOOK="docs/acceptance/m8.3/wp2-a3/h2-15-r1-a01-readiness-buffer-rescue.md"
COUNTS={"T1":39,"T2":35}
TOOLS=("bash","python3","script","getfacl","setfacl","fuser","stat","sha256sum",
       "git","uname","cat","id","wc","systemd-detect-virt","timeout")
LABELS=("N0-container","N0-vm","N0-context","N1-root","N1-branch","N1-head",
 "N1-status","N1-index","N1-baseline","N1-identities","N2-interpreters")+tuple(
 "N2-type-"+x for x in TOOLS)+("N2-bash-version","N2-python-version","N2-script-help",
 "N2-getfacl-help","N2-setfacl-help","N2-fuser-help","N2-stat-help","N2-sha-help","N2-timeout-help")
EXTRA=("N3-root","N3-ignored-path","N3-session","N3-ancestry-check")
D=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC
DISPOSITION=dict(N3="STOPPED",A_06="NOT QUALIFIED",decision_c="PENDING",
 R1_A01="UNDECLARED",physical_attempt_allowance_consumed=False)
class Stop(Exception):pass
def need(ok,code):
 if not ok:raise Stop(code)
def sha(b):return hashlib.sha256(b).hexdigest()
def encoded(x):return (json.dumps(x,sort_keys=True,indent=2)+"\n").encode()
def pairs(items):
 result={}
 for k,v in items:
  need(k not in result,"duplicate_json_key");result[k]=v
 return result
def parse(b):
 try:return json.loads(b,object_pairs_hook=pairs,parse_constant=lambda x:(_ for _ in ()).throw(Stop("nonfinite_json")))
 except (UnicodeError,json.JSONDecodeError):raise Stop("invalid_json") from None
def integer(x):return type(x) is int and x>0
def validate(raws,role,ctx):
 need(role in COUNTS and len(raws)==COUNTS[role],"record_count_mismatch")
 result=[];labels=[];last=-1
 for i,raw in enumerate(raws,1):
  need(type(raw) is bytes and 0<len(raw)<=98304 and b"\0" not in raw,"record_size_or_encoding")
  r=parse(raw);need(type(r) is dict,"record_not_object")
  label=r["label"];need(type(label) is str and re.fullmatch(r"[A-Za-z0-9_-]{1,64}",label),"invalid_label")
  labels.append(label)
  need(r["role"]==role and r["caller_shell_pid"]==ctx["shell_pid"] and
       r["tty"]==ctx["tty"] and r["boot_sha256"]==ctx["boot_sha256"],"record_context_mismatch")
  need(r["collector_sha256"]==COLLECTOR and r["pid1"]=="systemd" and
       r["interpreter"]==ctx["interpreter"],"record_source_mismatch")
  need(all(integer(r[k]) for k in ("caller_shell_pid","collector_pid","collector_parent")),"invalid_pid")
  if "child_pid" in r:need(integer(r["child_pid"]),"invalid_child_pid")
  need(type(r["started_ns"]) is int and type(r["ended_ns"]) is int and
       0<=r["started_ns"]<=r["ended_ns"] and r["started_ns"]>=last,"invalid_original_timestamps")
  last=r["ended_ns"]
  need(type(r["argv"]) is list and r["argv"] and all(type(x) is str for x in r["argv"])
       and sum(map(len,r["argv"]))<=8192,"invalid_original_argv")
  need(type(r["complete"]) is bool and (r["failure"] is None or type(r["failure"]) is str),"invalid_completion")
  need(r["complete"] is (r["failure"] is None),"inconsistent_completion")
  need(r["returncode"] is None or type(r["returncode"]) is int,"invalid_returncode")
  need(type(r["output_b64"]) is str and type(r["output_bytes"]) is int,"invalid_output_metadata")
  try:out=base64.b64decode(r["output_b64"],validate=True)
  except (ValueError,base64.binascii.Error):raise Stop("invalid_base64") from None
  need(0<=len(out)<=65536 and len(out)==r["output_bytes"] and sha(out)==r["output_sha256"],"output_integrity_mismatch")
  result.append((f"{i:02d}-{label}",raw,out,r))
 need(len(set(labels))==len(labels) and tuple(labels)==LABELS+(EXTRA if role=="T1" else ()),"unexpected_or_duplicate_labels")
 for label,value,status in (("N0-container",b"none",1),("N0-vm",b"vmware",0)):
  out,r=next((out,r) for _,_,out,r in result if r["label"]==label)
  need(out.strip()==value and r["returncode"]==status and r["complete"] is True,"original_environment_corroboration_missing")
 context=parse(next(out for _,_,out,r in result if r["label"]=="N0-context"))
 need(context["uid"]==ctx["uid"] and context["tty"]==ctx["tty"] and
      sha((context["boot_id"]+"\n").encode())==ctx["boot_sha256"],"original_native_context_mismatch")
 if role=="T1":
  session=parse(next(out for _,_,out,r in result if r["label"]=="N3-session"))
  a=next((out,r) for _,_,out,r in result if r["label"]=="N3-ancestry-check")
  ancestry=parse(a[0])
  need(session["preparation_session"]=="readiness_02" and
       ancestry["event"]=="N3_ANCESTRY_COMPATIBLE" and ancestry["read_only"] is True and
       ancestry["campaign"]=="campaign_02" and ancestry["preparation_session"]=="readiness_02" and
       a[1]["complete"] is True and a[1]["returncode"]==0,"missing_original_ancestry_confirmation")
 return result
def stream(raws):return b"".join(x+b"\0" for x in raws)
def read_stream(role):
 limit=COUNTS[role]*(98304+1)
 b=sys.stdin.buffer.read(limit+1)
 need(len(b)<=limit and b.endswith(b"\0"),"invalid_transport_bound_or_termination")
 return b[:-1].split(b"\0")
def dircheck(fd,private):
 s=os.fstat(fd)
 need(stat.S_ISDIR(s.st_mode) and s.st_uid in (0,os.geteuid()) and
      not stat.S_IMODE(s.st_mode)&0o022,"unsafe_directory_ancestry")
 if private:need(s.st_uid==os.geteuid() and stat.S_IMODE(s.st_mode)==0o700,"nonprivate_directory")
 return [s.st_dev,s.st_ino]
def child(parent,name,private=False):
 before=os.stat(name,dir_fd=parent,follow_symlinks=False)
 need(stat.S_ISDIR(before.st_mode),"symlink_or_nondirectory")
 fd=os.open(name,D,dir_fd=parent)
 need(dircheck(fd,private)==[before.st_dev,before.st_ino],"directory_changed")
 return fd
def walk(path):
 p=Path(path);need(p.is_absolute() and len(p.parts)<=32,"invalid_root_path")
 fd=os.open("/",D);dircheck(fd,False)
 for name in p.parts[1:]:
  need(name not in (".",".."),"path_escape")
  nxt=child(fd,name);os.close(fd);fd=nxt
 return fd
def fresh(parent,name):
 os.mkdir(name,0o700,dir_fd=parent)
 return child(parent,name,True)
def exists(parent,name):
 try:os.stat(name,dir_fd=parent,follow_symlinks=False);return True
 except FileNotFoundError:return False
def capacity(fd):
 s=os.fstatvfs(fd);need(s.f_bavail*s.f_frsize>=64*1024*1024,"storage_margin_below_64_MiB")
def base(repo,create=False):
 fd=walk(Path(repo)/".local/qualification/m8-3");capacity(fd)
 if not exists(fd,"wp2-a3-r1"):
  need(create,"private_root_missing");nxt=fresh(fd,"wp2-a3-r1")
 else:nxt=child(fd,"wp2-a3-r1",True)
 os.close(fd);capacity(nxt);return nxt
def preview(repo):
 fd=walk(Path(repo)/".local/qualification/m8-3");capacity(fd)
 present=exists(fd,"wp2-a3-r1")
 if present:
  nxt=child(fd,"wp2-a3-r1",True);os.close(fd);fd=nxt
  need(not exists(fd,RECOVERY),"recovery_target_exists")
 else:need(os.access(".",os.W_OK|os.X_OK,dir_fd=fd,effective_ids=True),"private_root_not_creatable")
 capacity(fd);os.close(fd)
 return dict(private_root_exists=present,recovery_target_absent=True)
def recovery(repo):
 fd=base(repo);nxt=child(fd,RECOVERY,True);os.close(fd);return nxt
def read(fd,name,limit):
 need("/" not in name and name not in (".",".."),"invalid_file_name")
 before=os.stat(name,dir_fd=fd,follow_symlinks=False)
 need(stat.S_ISREG(before.st_mode) and before.st_uid==os.geteuid() and
      stat.S_IMODE(before.st_mode)==0o600,"unsafe_evidence_file")
 raw=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK|os.O_NOCTTY,dir_fd=fd)
 with os.fdopen(raw,"rb") as f:
  s=os.fstat(f.fileno())
  need(stat.S_ISREG(s.st_mode) and s.st_uid==os.geteuid() and
       stat.S_IMODE(s.st_mode)==0o600 and
       [s.st_dev,s.st_ino]==[before.st_dev,before.st_ino],"unsafe_evidence_file")
  b=f.read(limit+1)
 need(len(b)<=limit,"evidence_file_bound")
 return b
def put(fd,name,b):
 raw=os.open(name,os.O_RDWR|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600,dir_fd=fd)
 with os.fdopen(raw,"w+b") as f:
  need(stat.S_IMODE(os.fstat(f.fileno()).st_mode)==0o600,"new_file_mode")
  f.write(b);f.flush();os.fsync(f.fileno());f.seek(0)
  need(f.read(len(b)+1)==b,"new_file_readback_mismatch")
def names(fd):
 result=set()
 with os.scandir(fd) as it:
  for entry in it:
   need(len(result)<512,"directory_entry_bound");result.add(entry.name)
 return result
def common_check(fd,ctx,collector,program):
 meta=parse(read(fd,"recovery.json",65536))
 need(meta["recovery_id"]==RECOVERY and meta["session"]=="readiness_02" and
      meta["proposed_campaign"]=="campaign_02" and meta["disposition"]==DISPOSITION,"wrong_recovery")
 need(meta["uid"]==ctx["uid"] and meta["boot_sha256"]==ctx["boot_sha256"],"cross_host_or_user_mismatch")
 need(meta["runbook_sha256"]==ctx["runbook_sha256"],"reviewed_runbook_mismatch")
 need(meta["directory_identity"]==dircheck(fd,True),"recovery_directory_changed")
 need(read(fd,"collector-source.py",32768)==collector and sha(collector)==COLLECTOR,"collector_copy_mismatch")
 need(read(fd,"rescue-program.py",65536)==program and meta["program_sha256"]==sha(program),"rescue_source_mismatch")
 expiry=meta["checkpoint_expiry"]
 need(expiry==dict(checkpoint="CREATE-CUSTODY",seconds=120,outcome="EXPIRED",
      creation_operation_reached=False,provenance="operator_attestation",
      original_expiry_capture_available=False),"missing_expiry_attestation")
 return meta
def save(repo,role,raws,ctx,collector,program,expected,approved_book_sha):
 rows=validate(raws,role,ctx);need(sha(stream(raws))==expected,"live_array_changed")
 need(sha(collector)==COLLECTOR,"collector_digest_mismatch")
 need(ctx["operator_attestation"]=="CURRENT-"+role+"-readiness_02","missing_current_session_attestation")
 if role=="T1":
  need(ctx.get("expiry_attestation")=="EXPIRED-CREATE-CUSTODY-120","expiry_not_attested")
  parent=base(repo,True)
  fd=fresh(parent,RECOVERY);os.fsync(parent);os.close(parent)
  meta=dict(recovery_id=RECOVERY,session="readiness_02",proposed_campaign="campaign_02",
   artifact_class="volatile_evidence_rescue_not_N3_completion",disposition=DISPOSITION,
   uid=ctx["uid"],boot_sha256=ctx["boot_sha256"],directory_identity=dircheck(fd,True),
   runbook_sha256=approved_book_sha,program_sha256=sha(program),handoff_sha256=HANDOFF,
   checkpoint_expiry=dict(checkpoint="CREATE-CUSTODY",seconds=120,outcome="EXPIRED",
    creation_operation_reached=False,provenance="operator_attestation",original_expiry_capture_available=False),
   recorded_at_ns=time.time_ns(),recorded_time_is_not_original_checkpoint_time=True)
  put(fd,"recovery.json",encoded(meta));put(fd,"collector-source.py",collector);put(fd,"rescue-program.py",program)
 else:
  fd=recovery(repo);common_check(fd,ctx,collector,program)
  need(names(fd)=={"recovery.json","collector-source.py","rescue-program.py","T1"},"unexpected_partial_recovery")
  verify_role(fd,"T1")
 rolefd=fresh(fd,role);items=[]
 for stem,raw,out,r in rows:
  status={k:r[k] for k in ("returncode","complete","failure")}
  put(rolefd,stem+".json",raw);put(rolefd,stem+".out",out);put(rolefd,stem+".status.json",encoded(status))
  items.append(dict(stem=stem,label=r["label"],json_sha256=sha(raw),output_sha256=sha(out),status=status))
 manifest=dict(role=role,count=len(rows),context=ctx,stream_sha256=sha(stream(raws)),
               records=items,directory_identity=dircheck(rolefd,True),
               metadata_kind="new_rescue_index_of_unchanged_originals")
 put(rolefd,"role-manifest.json",encoded(manifest));capacity(fd)
 os.fsync(rolefd);os.fsync(fd);os.close(rolefd);os.close(fd)
 return dict(event="ROLE_RESCUED",role=role,count=len(rows),normal_N3_completion=False)
def verify_role(fd,role):
 rolefd=child(fd,role,True);m=parse(read(rolefd,"role-manifest.json",131072))
 need(m["role"]==role and m["count"]==COUNTS[role] and len(m["records"])==COUNTS[role],"role_manifest_count")
 need(m["directory_identity"]==dircheck(rolefd,True),"role_directory_changed")
 raws=[];files={"role-manifest.json"}
 for item in m["records"]:
  stem=item["stem"];need(re.fullmatch(r"[0-9]{2}-[A-Za-z0-9_-]{1,64}",stem),"invalid_stem")
  raw=read(rolefd,stem+".json",98304);out=read(rolefd,stem+".out",65536)
  status=parse(read(rolefd,stem+".status.json",4096));r=parse(raw)
  need(sha(raw)==item["json_sha256"] and sha(out)==item["output_sha256"],"stored_file_hash_mismatch")
  need(status==item["status"]=={k:r[k] for k in ("returncode","complete","failure")},"status_changed")
  need(item["label"]==r["label"],"label_changed")
  try:decoded=base64.b64decode(r["output_b64"],validate=True)
  except (ValueError,base64.binascii.Error):raise Stop("invalid_stored_base64") from None
  need(out==decoded,"decoded_output_changed")
  raws.append(raw);files.update((stem+".json",stem+".out",stem+".status.json"))
 rows=validate(raws,role,m["context"])
 need([x[0] for x in rows]==[x["stem"] for x in m["records"]],"original_order_changed")
 need(sha(stream(raws))==m["stream_sha256"],"original_stream_changed")
 need(names(rolefd)==files,"unexpected_or_missing_role_files")
 os.close(rolefd);return m
def inspect_bundle(repo,ctx,collector,program):
 fd=recovery(repo);meta=common_check(fd,ctx,collector,program)
 roles={role:verify_role(fd,role) for role in COUNTS}
 a,b=(roles[x]["context"] for x in ("T1","T2"))
 need(a["boot_sha256"]==b["boot_sha256"]==meta["boot_sha256"] and a["uid"]==b["uid"]==meta["uid"],"roles_not_same_boot_or_user")
 need(a["tty"]!=b["tty"] and a["shell_pid"]!=b["shell_pid"],"terminals_not_independent")
 need(a["operator_attestation"]=="CURRENT-T1-readiness_02" and
      b["operator_attestation"]=="CURRENT-T2-readiness_02","session_membership_not_attested")
 allowed={"recovery.json","collector-source.py","rescue-program.py","T1","T2"}
 need(names(fd) in (allowed,allowed|{"artifact-inventory.json","artifact-inventory.sha256"}),"partial_or_unexpected_bundle")
 return fd,meta,roles
def file_inventory(fd):
 result=[]
 def add(d,name,prefix):
  b=read(d,name,131072);s=os.stat(name,dir_fd=d,follow_symlinks=False)
  result.append(dict(path=prefix+name,bytes=len(b),sha256=sha(b),object=[s.st_dev,s.st_ino]))
 for name in sorted(names(fd)-{"artifact-inventory.json","artifact-inventory.sha256"}):
  if name in COUNTS:
   sub=child(fd,name,True)
   for filename in sorted(names(sub)):add(sub,filename,name+"/")
   os.close(sub)
  else:add(fd,name,"")
 need(len(result)<=512 and sum(x["bytes"] for x in result)<=16*1024*1024,"bundle_size_bound")
 return result
def seal(repo,ctx,collector,program):
 fd,_,_=inspect_bundle(repo,ctx,collector,program)
 need(not exists(fd,"artifact-inventory.json") and not exists(fd,"artifact-inventory.sha256"),"inventory_target_exists")
 data=encoded(dict(kind="rescue_inventory_not_qualification",counts=COUNTS,disposition=DISPOSITION,
                   files=file_inventory(fd)))
 put(fd,"artifact-inventory.json",data)
 put(fd,"artifact-inventory.sha256",(sha(data)+"  artifact-inventory.json\n").encode())
 capacity(fd);os.fsync(fd);os.close(fd)
 return dict(event="RESCUE_INVENTORY_CREATED",counts=COUNTS)
def verify(repo,ctx,collector,program):
 fd,_,_=inspect_bundle(repo,ctx,collector,program)
 data=read(fd,"artifact-inventory.json",131072);inv=parse(data)
 need(read(fd,"artifact-inventory.sha256",128)==(sha(data)+"  artifact-inventory.json\n").encode(),"inventory_digest_mismatch")
 need(inv["counts"]==COUNTS and inv["disposition"]==DISPOSITION and
      inv["files"]==file_inventory(fd),"inventory_content_mismatch")
 os.close(fd)
 return dict(event="EVIDENCE_RESCUED_SUCCESSFULLY",counts=COUNTS,disposition=DISPOSITION,
             no_continuation_to_N4=True)
def verify_live(repo,role,raws,ctx,collector,program,expected):
 rows=validate(raws,role,ctx);need(sha(stream(raws))==expected,"live_array_changed")
 result=verify(repo,ctx,collector,program)
 fd=recovery(repo);sub=child(fd,role,True)
 for stem,raw,_,_ in rows:need(read(sub,stem+".json",98304)==raw,"archive_differs_from_live_array")
 os.close(sub);os.close(fd);result["live_role_compared"]=role
 return result
def source_bytes(path,limit=1024*1024):
 before=path.lstat();need(stat.S_ISREG(before.st_mode),"source_not_direct_regular_file")
 fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC|os.O_NONBLOCK|os.O_NOCTTY)
 with os.fdopen(fd,"rb") as f:
  s=os.fstat(f.fileno())
  need([s.st_dev,s.st_ino]==[before.st_dev,before.st_ino] and stat.S_ISREG(s.st_mode),"source_changed")
  b=f.read(limit+1)
 need(len(b)<=limit,"source_size_bound");return b
def native(role,shell_pid,book_sha):
 need(Path.cwd()==REPO and os.geteuid()!=0 and os.isatty(1),"native_terminal_not_established")
 need(Path("/proc/1/comm").read_text().strip()=="systemd","non_native_pid1")
 for p in ("/run/.containerenv","/.dockerenv","/.flatpak-info"):need(not Path(p).exists(),"container_marker")
 for k in ("SSH_CONNECTION","SSH_TTY","container","FLATPAK_ID","SNAP","CODEX_SANDBOX"):
  need(not os.environ.get(k),"remote_or_isolated_context")
 for line in Path("/proc/self/status").read_text().splitlines():
  k,_,v=line.partition(":")
  if k in ("NoNewPrivs","Seccomp"):need(v.strip()=="0","restricted_context_requires_review")
 values={}
 for line in Path("/etc/os-release").read_text().splitlines():
  k,_,v=line.partition("=")
  if k in ("ID","VERSION_ID","VARIANT_ID"):values[k]=v.strip(chr(34))
 need(values==dict(ID="fedora",VERSION_ID="44",VARIANT_ID="kinoite") and
      platform.machine()=="aarch64","unexpected_native_environment")
 collector=(os.environ["h215_rescue_collector"]+"\n").encode()
 program=(os.environ["h215_rescue_program"]+"\n").encode()
 need(sha(collector)==COLLECTOR,"live_collector_source_changed")
 handoff=source_bytes(REPO/"docs/acceptance/m8.3/wp2-a3/h2-15-r1-a01-native-operator-handoff.md")
 need(sha(handoff)==HANDOFF,"handoff_source_changed")
 book=source_bytes(REPO/BOOK);need(sha(book)==book_sha,"reviewed_rescue_runbook_changed")
 match=re.search(rb"<<'PYRESCUE'[^\n]*\n(.*?)^PYRESCUE$",book,re.M|re.S)
 need(match is not None and match[1]==program,"rescue_program_not_reviewed_bytes")
 boot=sha(Path("/proc/sys/kernel/random/boot_id").read_bytes())
 return dict(uid=os.geteuid(),shell_pid=int(shell_pid),tty=os.ttyname(1),boot_sha256=boot,
  interpreter=sys.executable,runbook_sha256=book_sha,operator_attestation="CURRENT-"+role+"-readiness_02",
  rescue_pid=os.getpid(),rescue_parent=os.getppid()),collector,program
def main():
 operation,role,shell_pid,book_sha,expected,ack=sys.argv[1:]
 need(operation in ("preflight","save","seal","verify") and role in COUNTS,"invalid_rescue_operation")
 need(re.fullmatch(r"[0-9a-f]{64}",book_sha),"invalid_reviewed_digest")
 required_ack="CURRENT-"+role+"-readiness_02"+(":EXPIRED-CREATE-CUSTODY-120" if role=="T1" else "")
 need(ack==required_ack,"operator_session_confirmation_required")
 signal.signal(signal.SIGALRM,lambda *_:(_ for _ in ()).throw(Stop("rescue_watchdog")))
 signal.alarm(120);os.umask(0o077)
 ctx,collector,program=native(role,shell_pid,book_sha)
 ctx["expiry_attestation"]="EXPIRED-CREATE-CUSTODY-120" if role=="T1" else None
 if operation in ("preflight","save","verify"):
  raws=read_stream(role);rows=validate(raws,role,ctx)
  if operation=="preflight":
   ancestry=preview(REPO)
   result=dict(event="RESCUE_PREFLIGHT_ONLY",role=role,count=len(rows),shell_pid=ctx["shell_pid"],
    tty=ctx["tty"],stream_sha256=sha(stream(raws)),collector_sha256=COLLECTOR,
    first_started_ns=rows[0][3]["started_ns"],last_ended_ns=rows[-1][3]["ended_ns"],
    incomplete_captures=sum(not r["complete"] for _,_,_,r in rows),custody_created=False,ancestry=ancestry)
  elif operation=="save":result=save(REPO,role,raws,ctx,collector,program,expected,book_sha)
  else:result=verify_live(REPO,role,raws,ctx,collector,program,expected)
 elif operation=="seal":
  need(role=="T1","T1_only_inventory_writer");result=seal(REPO,ctx,collector,program)
 signal.alarm(0);print(json.dumps(result,sort_keys=True),flush=True)
if __name__=="__main__":
 try:main()
 except (Stop,OSError,KeyError,UnicodeError,KeyboardInterrupt) as e:
  code=str(e) if isinstance(e,Stop) else type(e).__name__
  print(json.dumps(dict(event="RESCUE_STOP",condition=code,partial_artifacts_left_untouched=True)),flush=True)
  sys.exit(2)
PYRESCUE
}
if h215_rescue_load; then
  printf '%s\n' 'Rescue program loaded only; review before running any operation.'
else
  printf '%s\n' 'STOP: keep the terminal and original buffers open; seek review.' >&2
fi
~~~

The program uses only Python's standard library. Its live CLI requires an
ordinary native Fedora 44/Kinoite/aarch64 systemd/VMware terminal, no detected
container/remote/restricted context, the exact handoff/source identities and
the independently reviewed runbook hash. Unsupported context is STOP, not a
reason to change sandbox flags. Private boot material is stored only privately.
Every noninteractive rescue operation has a 120-second I/O watchdog, separate
from the historical expired prompt. It changes no physical deadline and cannot
force cancellation of uninterruptible kernel work or survive SIGKILL/VM loss.

## 2 — Load shell guards and operations

Do not run these functions in a subshell or pipe the entire function. They
return to the interactive caller; none terminates that shell. No complete array
or record is printed to the terminal. Transport goes only through the private
pipe to the approved rescue program, which prints bounded summaries.

~~~bash
h215_rescue_check() {
  [[ -n ${BASH_VERSION:-} && $- != *x* && -t 0 && -t 1 ]] || return 1
  [[ ! ${BASH_ENV+x} && ! ${ENV+x} ]] || return 1
  [[ ${h215_repo:-} == /var/home/user/Projects/grocery-pos-platform ]] || return 1
  [[ "$(pwd -P)" == "$h215_repo" && "${h215_shell_pid:-}" == "$BASHPID" ]] || return 1
  [[ -v h215_sink && -z "$h215_sink" && -n ${h215_collector:-} ]] || return 1
  [[ ${h215_python:-} == /* && -f "$h215_python" && -x "$h215_python" ]] || return 1
  [[ ${h215_records@a} == a ]] || return 1
  local expected i
  case "${h215_role:-}" in
    T1)
      expected=39
      [[ ${h215_n3_status:-} == STOPPED && ${h215_n3_entered:-} == yes ]] || return 1
      [[ ${h215_readiness_session:-} == readiness_02 && ${h215_campaign:-} == campaign_02 ]] || return 1
      ;;
    T2)
      expected=35
      [[ ! ${h215_n3_status+x} && ! ${h215_n3_entered+x} ]] || return 1
      ;;
    *) return 1 ;;
  esac
  [[ ${h215_count:-} == "$expected" && ${#h215_records[@]} == "$expected" ]] || return 1
  for ((i=0;i<expected;i++)); do [[ -v h215_records[$i] && -n ${h215_records[$i]} ]] || return 1; done
}
h215_rescue_invoke() {
  local operation=$1 shell_pid=$BASHPID
  h215_rescue_check || return 1
  [[ ${h215_rescue_reviewed_sha:-} =~ ^[0-9a-f]{64}$ ]] || return 1
  if [[ "$operation" == seal ]]; then
    h215_rescue_collector="$h215_collector" h215_rescue_program="$h215_rescue_code" \
      "$h215_python" -B -c "$h215_rescue_code" "$operation" "$h215_role" "$shell_pid" \
      "$h215_rescue_reviewed_sha" "${h215_rescue_digest:-}" "$h215_rescue_ack"
  else
    printf '%s\0' "${h215_records[@]}" |
      h215_rescue_collector="$h215_collector" h215_rescue_program="$h215_rescue_code" \
      "$h215_python" -B -c "$h215_rescue_code" "$operation" "$h215_role" "$shell_pid" \
      "$h215_rescue_reviewed_sha" "${h215_rescue_digest:-}" "$h215_rescue_ack"
  fi
}
h215_rescue_preflight() {
  [[ ! ${h215_rescue_preflight_started+x} ]] || return 1
  h215_rescue_preflight_started=yes
  h215_rescue_check || return 1
  read -r -p 'Independently reviewed rescue-runbook SHA-256: ' h215_rescue_reviewed_sha || return 1
  read -r -p 'Confirm CURRENT-T1-readiness_02 or CURRENT-T2-readiness_02, matching this identified window: ' h215_rescue_ack || return 1
  [[ "$h215_rescue_ack" == "CURRENT-$h215_role-readiness_02" ]] || return 1
  if [[ "$h215_role" == T1 ]]; then
    read -r -p 'Attest expired confirmation, creation not reached; type EXPIRED-CREATE-CUSTODY-120: ' h215_rescue_expiry || return 1
    [[ "$h215_rescue_expiry" == EXPIRED-CREATE-CUSTODY-120 ]] || return 1
    h215_rescue_ack="$h215_rescue_ack:$h215_rescue_expiry"
  fi
  h215_rescue_invoke preflight || return 1
  read -r -p 'After reviewing this summary, copy its stream_sha256: ' h215_rescue_digest || return 1
  [[ "$h215_rescue_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  h215_rescue_preflight_ok=yes
}
h215_rescue_save() {
  [[ ! ${h215_rescue_save_started+x} && ${h215_rescue_preflight_ok:-} == yes ]] || return 1
  h215_rescue_save_started=yes
  local approval
  read -r -p 'After specific human approval, type RESCUE-ONLY-rescue_readiness_02_n3_timeout_01: ' approval || return 1
  [[ "$approval" == RESCUE-ONLY-rescue_readiness_02_n3_timeout_01 ]] || return 1
  h215_rescue_invoke save || return 1
  h215_rescue_check || return 1
  h215_rescue_saved=yes
}
h215_rescue_seal() {
  [[ "$h215_role" == T1 && ${h215_rescue_saved:-} == yes && ! ${h215_rescue_seal_started+x} ]] || return 1
  h215_rescue_seal_started=yes
  h215_rescue_invoke seal || return 1
}
h215_rescue_verify() {
  [[ ${h215_rescue_saved:-} == yes && ! ${h215_rescue_verify_started+x} ]] || return 1
  h215_rescue_verify_started=yes
  h215_rescue_invoke verify || return 1
  h215_rescue_check || return 1
}
~~~

The reviewed runbook digest must come from independent review, not merely a
fresh self-hash treated as approval. The program independently checks its
loaded bytes against that reviewed document, and the collector against the
pinned handoff hash and every original record. Original VMware/container
outputs are checked in their preserved captures, not re-executed. Current
process, OS, TTY and same-boot checks are new rescue guards; intended-guest
identification remains an explicit human attestation. A wrong digest or changed array
stops before preservation. Do not enable tracing, print records, alter original
variables or bypass a mismatch. The current role's source/time/TTY/PID summary
must match the human's identification of that terminal.

## 3 — Execute only after rescue-specific approval

Approval remains **PENDING** in this candidate. The owner must identify the
reviewed document digest, exact recovery path, current T1/T2 terminals and scope:
read-only rescue guards, exclusive private preservation, inventory creation and
read-only verification. No scanner/device/ACL/physical operation or N3 restart
is included. Operational acknowledgement tokens do not create human authority.

Run each following block separately at the stated point, never all at once.
Failure means STOP; leave both shells open, preserve partial output and seek
human review. Do not clear a latch or retry with another identifier.

First run in **each** selected terminal:

~~~bash
if h215_rescue_preflight; then
  printf '%s\n' 'Read-only rescue preflight complete; no custody created.'
else
  printf '%s\n' 'STOP: discrepancy or incomplete preflight; keep original buffers open.' >&2
fi
~~~

Review both summaries and explicitly exclude the older T2. Context checks are
new rescue guards, not recaptured original readiness evidence. Original
incomplete/failure metadata is preserved as such, never promoted to completion.

Then in **T1 only**, following the owner's location/scope approval:

~~~bash
if h215_rescue_save; then
  printf '%s\n' 'T1 originals preserved; N3 remains STOPPED. Keep the live array.'
else
  printf '%s\n' 'STOP: retain partial recovery and live arrays; no retry before review.' >&2
fi
~~~

T2 must wait for T1's successful save. Then run in **current T2 only**:

~~~bash
if h215_rescue_save; then
  printf '%s\n' 'T2 originals preserved separately; N3 was not entered. Keep the live array.'
else
  printf '%s\n' 'STOP: retain partial recovery and live arrays; no retry before review.' >&2
fi
~~~

Only after both saves succeed, run in **T1 only**:

~~~bash
if h215_rescue_seal; then
  printf '%s\n' 'Private artifact inventory created; this is not qualification.'
else
  printf '%s\n' 'STOP: bundle is partial or invalid; do not overwrite or reseal.' >&2
fi
~~~

Finally run this **separate read-only verification** in **both** terminals:

~~~bash
if h215_rescue_verify; then
  printf '%s\n' 'Stored bundle verified against this terminal original array; review both terminal results.'
else
  printf '%s\n' 'STOP: independent read-back failed; preserve all files and buffers.' >&2
fi
~~~

The verification operation uses only read-only file/directory opens. It reparses
the stored originals and status derivatives, validates the inventory and source
copies, enforces 39/35 counts and original order, checks role separation, original
shell/collector/TTY/boot provenance and compares the current role's archived JSON
against its still-live array. It is a separate operation, not a second independent
implementation of the decoding algorithms. Both live-role comparisons and human
review are required before declaring rescue successful.

## Bundle contents and independent review

| Artifact | Meaning |
| --- | --- |
| recovery.json | New rescue provenance, reviewed runbook digest, exact operator-attested expired checkpoint and unchanged nonqualification disposition |
| collector-source.py | Exact existing collector source plus the LF used by its recorded digest convention |
| rescue-program.py | Reviewed rescue program bytes; no original program or diagnostic modified |
| T1/ and T2/ | Exclusively created private role directories, with 39 and 35 records respectively |
| NN-original-label.json | Exact original available Bash-string JSON bytes, without an added LF |
| NN-original-label.out | Exact base64-decoded merged stdout/stderr bytes |
| NN-original-label.status.json | Generated derivative of the original returncode/complete/failure fields |
| role-manifest.json | New per-role rescue index, original-context attribution and raw transport digest |
| artifact-inventory.json / .sha256 | New private file inventory and its digest; excludes itself and its digest sidecar to avoid self-reference |

These are planned filenames, not assertions that files exist. Each artifact is
regular, owner-owned 0600; directories are 0700 within the trusted ancestry.
The inventory hashes every original/derivative/source file and records byte
counts and observed filesystem identities. It excludes only its own two files,
which are separately digest-checked. Unexpected files, symlinks, missing roles,
bad hashes/counts or partial recovery prevent success. No manifest represents
normal N3 completion or an experiment execution ledger.

The reviewer must confirm exact recorded metadata and hashes, live-array
comparisons from both correct terminals, T2's explicitly attested session
membership, the expiry-attestation limitation, unchanged original shell state,
and all partial/failure outcomes. Preserve original bytes privately, without
redaction or normalization. Do not export or publish raw records, boot identifiers,
credentials, barcode data or USB serial information. No off-host transfer is
authorized. Same-VM custody is not an independent backup.

## Disposition and stop boundary

Only after preservation, inventory verification and both live-role comparisons:

- **Evidence rescued successfully:** 39 T1 plus 35 T2 original records verified.
- **N3 preparation remained STOPPED:** no expired checkpoint was resumed.
- **A-06 not qualified:** rescue storage is not normal preparation readiness.
- **Decision C pending; R1-A01 undeclared; no physical allowance consumed.**

No success message authorizes continuation to N4, a synchronization/acquisition
scan or a physical attempt. Keep arrays intact until independent human review.
A later complete readiness collection needs a separately identified session and
human review. Missing earlier T1 evidence from the older incident remains missing;
nothing here reconstructs it. The older separately attributable T2 remains outside
this rescue.

An error, timeout, interruption or uncertain partial write stops the operation.
There is no deletion, overwrite, auto-retry, automatic N3 restart or STOPPED-latch
change. A file may be partly preserved after failure; report that fact and seek
a specifically reviewed next preservation step, rather than making a new green
bundle. Shell survival cannot guarantee survival after terminal close, SIGKILL,
VM shutdown/rollback or storage failure.

## Validation and remaining limitations

This runbook received static Bash/Python, source-hash, link, whitespace, privacy
and scope checks. Synthetic in-memory records exercised the same preservation
and read-back functions only in isolated temporary storage. The synthetic report
below records actual test outcomes; it is not native or H-VM qualification.

**Synthetic result: 40 tests PASS; 0 failures, 0 errors.**

A transient standard-library unittest harness loaded only program definitions,
replaced native context acquisition with a function that fails if called, and
used generated in-memory records plus exclusively created temporary fixtures
inside the isolated command runner. The fixture path walker was anchored at its
new 0700 temporary directory; shared/private directory checks remained active
within the fixture. Production CLI root/context restrictions were not relaxed.
No native buffers or actual qualification paths were used. Synthetic fixture
cleanup does not authorize deleting any real partial rescue.

The Bash source-loading test read authored collector source as inert text;
it did not execute that collector. Native interactive guard behavior, actual
terminal selection, permissions and kernel/storage failure behavior remain
unqualified. The transient harness is not a committed acceptance runner.

| Test | Result |
| --- | --- |
| test_01_all_74_original_json_and_binary_outputs_preserved | PASS |
| test_02_changed_recorded_output_hash_rejected_before_creation | PASS |
| test_03_count_mismatch_rejected_before_creation | PASS |
| test_04_existing_recovery_collision_no_overwrite | PASS |
| test_05_group_writable_shared_ancestor_rejected | PASS |
| test_06_nonprivate_existing_custody_root_rejected | PASS |
| test_07_parent_symlink_rejected | PASS |
| test_08_interrupted_initial_write_partial_original_retained | PASS |
| test_09_T1_only_cannot_seal_partial_recovery | PASS |
| test_10_stored_output_mutation_detected | PASS |
| test_11_duplicate_labels_rejected | PASS |
| test_12_invalid_base64_rejected | PASS |
| test_13_role_contamination_rejected | PASS |
| test_14_collector_source_mismatch_rejected | PASS |
| test_15_original_shell_provenance_mismatch_rejected | PASS |
| test_16_original_completion_failure_retained_without_promotion | PASS |
| test_17_undeclared_dispositions_and_expiry_attestation_explicit | PASS |
| test_18_expiry_not_attested_rejected_before_creation | PASS |
| test_19_foreign_boot_T2_rejected_without_role_creation | PASS |
| test_20_read_only_verifier_does_not_call_writer_or_change_files | PASS |
| test_21_each_live_role_compared_with_archive | PASS |
| test_22_changed_live_array_fingerprint_rejected | PASS |
| test_23_unexpected_file_and_inventory_tamper_rejected | PASS |
| test_24_seal_is_exclusive_no_replacement | PASS |
| test_25_partial_T2_write_keeps_T1_and_partial_T2 | PASS |
| test_26_inventory_digest_tamper_rejected | PASS |
| test_27_synthetic_bash_read_source_digest_convention_matches | PASS |
| test_28_maximum_output_boundary_preserved | PASS |
| test_29_oversized_output_rejected_before_creation | PASS |
| test_30_unexpected_partial_bundle_blocks_T2_before_writing | PASS |
| test_31_evidence_symlink_rejected_by_read_only_verifier | PASS |
| test_32_reviewed_runbook_mismatch_blocks_T2 | PASS |
| test_33_read_only_custody_preview_does_not_create_root | PASS |
| test_34_existing_target_is_preflight_stop | PASS |
| test_35_insufficient_capacity_stops_before_private_root_creation | PASS |
| test_36_private_modes_and_existing_0755_ancestors_preserved | PASS |
| test_37_native_guard_never_reexecutes_original_commands | PASS |
| test_38_original_environment_corroboration_mismatch_stops | PASS |
| test_39_NUL_transport_preserves_exact_available_JSON_bytes | PASS |
| test_40_missing_transport_terminator_rejected | PASS |

No live buffer, native command, actual qualification-custody directory, USB/TTY
endpoint, scanner diagnostic, ACL or physical experiment was accessed by Codex.
No Decision C, qualifying-cycle credit, staging or Git history operation occurred.
