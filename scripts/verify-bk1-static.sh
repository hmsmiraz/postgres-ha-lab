#!/usr/bin/env bash
# Static checks for the BK-1 implementation (k8s/pg/25-pgbackrest.yaml, 20-config.yaml, 50-statefulset.yaml, loop script).
# Docker only: nothing here contacts the cluster. Every check prints PASS or FAIL, and the file ends with a verdict line.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. ./versions.env
pg_image="${IMAGE_NAME}:${IMAGE_TAG}"
fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
r=$(mktemp -d)
chmod 777 "$r"
# shellcheck disable=SC2329
cleanup() { rm -rf "$r"; }
trap cleanup EXIT
echo "date_utc: $(date -u +%FT%TZ)"

cp k8s/pg/50-statefulset.yaml "$r/sts.new.yaml"
cp k8s/pg/25-pgbackrest.yaml k8s/pg/20-config.yaml "$r/"
cp scripts/gen-objstore-secrets.sh "$r/gen.sh"
sed "s|__IMAGE__|${pg_image}|g" k8s/pg/50-statefulset.yaml >"$r/sts.yaml"

if kubeconform -strict -summary "$r/sts.yaml" "$r/25-pgbackrest.yaml" "$r/20-config.yaml" >"$r/kc.txt" 2>&1; then
  pass "kubeconform: $(tail -n 1 "$r/kc.txt")"
else
  bad "kubeconform: $(tail -n 3 "$r/kc.txt")"
fi

cat >"$r/check.py" <<'PY'
import copy
import yaml

W = "/w/"


def docs(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d]


def patroni(path):
    cm = docs(path)[0]
    return cm, yaml.safe_load(cm["data"]["patroni.yml"])


def named(items, name):
    for i in items:
        if i["name"] == name:
            return i
    return None


def sts_problems(new, env_cm, pat, gen_text):
    p = []
    spec = new["spec"]["template"]["spec"]
    pg = named(spec["containers"], "postgres")
    bk = named(spec["containers"], "backup")
    if pg is None or bk is None:
        return p + ["postgres or backup container missing"]
    if pg.get("startupProbe", {}).get("periodSeconds") != 5:
        p.append("postgres startup probe must run every five seconds")
    want_from = [{"configMapRef": {"name": "pgbackrest-env"}}]
    for c in (pg, bk):
        if c.get("envFrom") != want_from:
            p.append(c["name"] + ": envFrom is not the pgbackrest-env ConfigMap")
        envs = {e["name"]: e for e in c.get("env", [])}
        for var, key in (("PGBACKREST_REPO1_S3_KEY", "access-key-id"), ("PGBACKREST_REPO1_S3_KEY_SECRET", "secret-access-key")):
            ref = (envs.get(var) or {}).get("valueFrom", {}).get("secretKeyRef", {})
            if ref != {"name": "objstore-credentials", "key": key}:
                p.append("%s: %s is not read from objstore-credentials/%s" % (c["name"], var, key))
    for key in ("access-key-id", "secret-access-key"):
        if (key + ":") not in gen_text:
            p.append("gen-objstore-secrets.sh does not create the key " + key)
    pm = {m["name"]: m for m in pg.get("volumeMounts", [])}
    bm = {m["name"]: m for m in bk.get("volumeMounts", [])}
    ca = pm.get("objstore-ca", {})
    if ca.get("mountPath") != "/certs" or not ca.get("readOnly"):
        p.append("postgres: objstore-ca is not mounted read-only at /certs")
    for name, path, ro in (("data", "/pgdata", True), ("run", "/run/postgresql", False), ("tmp", "/tmp", False),
                           ("objstore-ca", "/certs", True), ("backup-scripts", "/scripts", True)):
        m = bm.get(name)
        if not m or m.get("mountPath") != path or bool(m.get("readOnly")) != ro:
            p.append("backup: volume %s is not mounted at %s (readOnly=%s)" % (name, path, ro))
    vols = {v["name"]: v for v in spec["volumes"]}
    sec = vols.get("objstore-ca", {}).get("secret", {})
    if sec.get("secretName") != "objstore-tls" or sec.get("items") != [{"key": "ca.crt", "path": "ca.crt"}]:
        p.append("volume objstore-ca is not the ca.crt of the Secret objstore-tls")
    if vols.get("backup-scripts", {}).get("configMap", {}).get("name") != "pgbackrest-scripts":
        p.append("volume backup-scripts is not the ConfigMap pgbackrest-scripts")
    sc = bk.get("securityContext", {})
    if sc.get("allowPrivilegeEscalation") is not False or sc.get("capabilities", {}).get("drop") != ["ALL"]:
        p.append("backup: securityContext does not forbid privilege escalation and drop ALL capabilities")
    if bk.get("command") != ["sh", "/scripts/backup-loop.sh"]:
        p.append("backup: command is not sh /scripts/backup-loop.sh")
    data = env_cm["data"]
    for key in data:
        up = key.upper()
        if "SECRET" in up or "PASSWORD" in up or "TOKEN" in up or up.endswith("_KEY"):
            p.append("ConfigMap pgbackrest-env has a key that looks like a secret: " + key)
    params = pat["bootstrap"]["dcs"]["postgresql"]["parameters"]
    if data.get("PGBACKREST_REPO1_STORAGE_CA_FILE") != "/certs/ca.crt":
        p.append("CA file path is not /certs/ca.crt")
    if data.get("PGBACKREST_PG1_PATH") != pat["postgresql"]["data_dir"]:
        p.append("PGBACKREST_PG1_PATH is not Patroni's data_dir")
    if data.get("PGBACKREST_PG1_SOCKET_PATH") != params.get("unix_socket_directories"):
        p.append("PGBACKREST_PG1_SOCKET_PATH is not unix_socket_directories")
    if ("--stanza=" + str(data.get("PGBACKREST_STANZA"))) not in params.get("archive_command", ""):
        p.append("archive_command does not use the stanza named in PGBACKREST_STANZA")
    if not str(data.get("PGBACKREST_PG1_PATH", "")).startswith(pm.get("data", {}).get("mountPath", "?") + "/"):
        p.append("PGBACKREST_PG1_PATH is not under the data volume mount of the postgres container")
    return p


def report(name, problems):
    if problems:
        print("FAIL: " + name + " (" + "; ".join(problems[:3]) + ")")
    else:
        print("PASS: " + name)


_, new_pat = patroni(W + "20-config.yaml")
params = new_pat["bootstrap"]["dcs"]["postgresql"]["parameters"]
report("WAL archiving enabled with pgBackRest archive-push",
       [] if params.get("archive_mode") == "on" and params.get("archive_command") == "pgbackrest --stanza=pg-ha archive-push %p" else ["archive configuration differs"])
new_sts = docs(W + "sts.new.yaml")[0]
cms = docs(W + "25-pgbackrest.yaml")
env_cm = named([{"name": d["metadata"]["name"], "d": d} for d in cms], "pgbackrest-env")["d"]
scripts_cm = named([{"name": d["metadata"]["name"], "d": d} for d in cms], "pgbackrest-scripts")["d"]
with open(W + "gen.sh") as f:
    gen_text = f.read()
report("50-statefulset.yaml: backup configuration, secret references and mounts are consistent",
       sts_problems(new_sts, env_cm, new_pat, gen_text))

mut = copy.deepcopy(new_sts)
mut["spec"]["template"]["spec"]["volumes"] = [v for v in mut["spec"]["template"]["spec"]["volumes"] if v["name"] != "objstore-ca"]
n = len(sts_problems(mut, env_cm, new_pat, gen_text))
print(("PASS" if n >= 1 else "FAIL") + ": control A (CA volume removed): the check reports %d problem(s)" % n)

mut = copy.deepcopy(new_sts)
for c in mut["spec"]["template"]["spec"]["containers"]:
    if c["name"] == "postgres":
        c["startupProbe"]["periodSeconds"] += 1
n = len(sts_problems(mut, env_cm, new_pat, gen_text))
print(("PASS" if n >= 1 else "FAIL") + ": control B (a probe changed): the check reports %d problem(s)" % n)

cm2 = copy.deepcopy(env_cm)
cm2["data"]["PGBACKREST_REPO1_S3_KEY_SECRET"] = "x"
n = len(sts_problems(new_sts, cm2, new_pat, gen_text))
print(("PASS" if n >= 1 else "FAIL") + ": control C (secret-like key in the ConfigMap): the check reports %d problem(s)" % n)

loop = scripts_cm["data"].get("backup-loop.sh", "")
with open(W + "loop.sh", "w") as f:
    f.write(loop)
print(("PASS" if loop.startswith("#!/bin/sh") else "FAIL") + ": backup-loop.sh extracted from the ConfigMap (%d lines)" % len(loop.splitlines()))
print("PYTHON CHECKS DONE")
PY

out=$(docker run --rm -v "$r:/w" --entrypoint python3 "$pg_image" /w/check.py 2>&1) || true
echo "$out"
case "$out" in
  *"PYTHON CHECKS DONE"*) ;;
  *) bad "the python checks did not finish" ;;
esac
n=$(grep -c '^FAIL' <<<"$out" || true)
if [ "${n:-0}" -ne 0 ]; then fail=1; fi

if [ -s "$r/loop.sh" ]; then
  if shellcheck -s sh "$r/loop.sh"; then pass "shellcheck is clean on backup-loop.sh"; else bad "shellcheck found problems in backup-loop.sh"; fi
  if docker run --rm -v "$r:/w:ro" --entrypoint sh "$pg_image" -n /w/loop.sh; then pass "backup-loop.sh passes sh -n in the pg-ha image"; else bad "sh -n failed on backup-loop.sh"; fi
else
  bad "backup-loop.sh was not extracted"
fi

cat >"$r/driver.sh" <<'DRV'
#!/bin/sh
mkdir -p /tmp/stubs
cat >/tmp/stubs/psql <<'EOS'
#!/bin/sh
if [ "${STUB_RECOVERY:-f}" = err ]; then exit 2; fi
echo "${STUB_RECOVERY:-f}"
EOS
cat >/tmp/stubs/pgbackrest <<'EOS'
#!/bin/sh
echo "$*" >>"$STUB_LOG"
case "$*" in
  *repo-ls*) if [ "${STUB_LISTING:-none}" = has ]; then echo backup.info; fi; exit 0 ;;
  *stanza-create*) exit "${STUB_CREATE_RC:-0}" ;;
esac
exit 0
EOS
chmod +x /tmp/stubs/psql /tmp/stubs/pgbackrest
PATH=/tmp/stubs:$PATH
export PATH PGBACKREST_STANZA=pg-ha BACKUP_LOOP_INTERVAL=1 BACKUP_LOOP_IDLE_INTERVAL=1 STUB_LOG=/tmp/stub.log
count() { awk -v p="$1" 'index($0, p) { n++ } END { print n + 0 }' /tmp/stub.log; }
run() {
  : >/tmp/stub.log
  STUB_RECOVERY=$2 STUB_LISTING=$3 STUB_CREATE_RC=$4 timeout 4 sh /w/loop.sh >/tmp/loop.out 2>&1
  rc=$?
  echo "SCENARIO $1: loop exit=$rc repo-ls=$(count repo-ls) stanza-create=$(count stanza-create)"
}
run primary-missing f none 0
run primary-present f has 0
run replica t none 0
run psql-error err none 0
run create-fails f none 1
: >/tmp/stub.log
STUB_RECOVERY=f STUB_LISTING=has STUB_CREATE_RC=0 BACKUP_LOOP_IDLE_INTERVAL=30 sh /w/loop.sh >/tmp/loop.out 2>&1 &
pid=$!
sleep 1
kill -TERM "$pid"
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then
  kill -KILL "$pid"
  echo "SCENARIO term: loop exit=none still-running=yes"
else
  wait "$pid"
  echo "SCENARIO term: loop exit=$? still-running=no"
fi
DRV
scen=$(docker run --rm -v "$r:/w" --entrypoint sh "$pg_image" /w/driver.sh 2>&1) || true
echo "$scen"
sc() { sed -n "s/^SCENARIO $1: .*$2=\([0-9a-z]*\).*/\1/p" <<<"$scen"; }
v=$(sc primary-missing stanza-create)
if [ "${v:-0}" -ge 1 ]; then pass "leader without a stanza: stanza-create runs"; else bad "leader without a stanza: stanza-create did not run"; fi
v=$(sc primary-present stanza-create)
w=$(sc primary-present repo-ls)
if [ "${v:-x}" = 0 ] && [ "${w:-0}" -ge 1 ]; then pass "leader with a stanza: repository listed, stanza-create not run"; else bad "leader with a stanza: stanza-create=${v:-?} repo-ls=${w:-?}"; fi
v=$(sc replica stanza-create)
w=$(sc replica repo-ls)
if [ "${v:-x}" = 0 ] && [ "${w:-x}" = 0 ]; then pass "replica: nothing is run"; else bad "replica: stanza-create=${v:-?} repo-ls=${w:-?}"; fi
v=$(sc psql-error stanza-create)
w=$(sc psql-error repo-ls)
if [ "${v:-x}" = 0 ] && [ "${w:-x}" = 0 ]; then pass "psql unavailable: nothing is run"; else bad "psql unavailable: stanza-create=${v:-?} repo-ls=${w:-?}"; fi
v=$(sc create-fails stanza-create)
if [ "${v:-0}" -ge 2 ]; then pass "stanza-create failing: the loop retries (stanza-create ran $v times in 4 s)"; else bad "stanza-create failing: ran ${v:-0} times, expected a retry"; fi
v=$(sed -n 's/^SCENARIO term: loop exit=\([0-9a-z]*\) .*/\1/p' <<<"$scen")
w=$(sed -n 's/^SCENARIO term: .*still-running=\([a-z]*\).*/\1/p' <<<"$scen")
if [ "${v:-x}" = 0 ] && [ "${w:-x}" = no ]; then pass "SIGTERM during the idle wait: the loop exits with status 0 within 3 s"; else bad "SIGTERM: exit=${v:-?} still-running=${w:-?}"; fi

if [ "$fail" -eq 0 ]; then echo "ALL BK-1 STATIC CHECKS PASSED"; else echo "BK-1 STATIC CHECKS FAILED"; fi
exit "$fail"
