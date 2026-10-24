#!/usr/bin/env python3
"""ตรวจ dashboard + alert rules (เรียกจาก validate.sh)

ใช้: validate_content.py <grafana_dir> <expected-metrics.txt>
จบด้วย exit 0 = ผ่าน, 1 = มีข้อผิดพลาด (พิมพ์ทีละข้อ)
"""
import glob
import json
import os
import re
import sys

import yaml

sys.stdout.reconfigure(encoding='utf-8')  # Windows console เป็น cp1252 โดยปริยาย

grafana_dir, expected_file = sys.argv[1], sys.argv[2]
errors = []


def err(m):
    errors.append(m)


THAI = re.compile(r'[฀-๿]')

# ── expected-metrics.txt ──
try:
    with open(expected_file, encoding='utf-8') as fh:
        expected = {ln.split('#')[0].strip() for ln in fh if ln.split('#')[0].strip()}
except OSError as e:
    print(f"  ✗ อ่าน expected-metrics.txt ไม่ได้: {e}")
    sys.exit(1)

# uid มาตรฐานของ Grafana Cloud (import.sh แทนที่ได้ถ้า stack ใช้ uid อื่น)
PROM_UIDS = {"grafanacloud-prom"}
LOKI_UIDS = {"grafanacloud-logs"}

KEYWORDS = {"and", "or", "unless", "bool", "offset", "by", "without", "on", "ignoring",
            "group_left", "group_right", "inf", "nan"}


def metric_names(expr):
    """ชื่อที่ดูเป็น metric ใน PromQL (ตัด string, label matcher, range, by(...), ชื่อฟังก์ชันออก)"""
    s = re.sub(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'|`[^`]*`', '""', expr)
    s = re.sub(r'\$\{[^}]*\}|\$\w+', '0', s)          # ตัวแปรของ Grafana
    s = re.sub(r'\[[^\]]*\]', '', s)                  # range selector
    s = re.sub(r'\{[^}]*\}', '', s)                   # label matcher
    s = re.sub(r'\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)', '', s)
    names = set()
    for m in re.finditer(r'(?<![\w.:])([A-Za-z_:][A-Za-z0-9_:]*)(?!\s*\()(?![\w:])', s):
        t = m.group(1)
        if t.lower() in KEYWORDS:
            continue
        names.add(t)
    return names


def check_prom(where, expr):
    if not expr.strip():
        err(f"{where}: expr ว่าง")
        return
    for n in sorted(metric_names(expr)):
        if n not in expected:
            err(f"{where}: ชื่อ metric '{n}' ไม่อยู่ใน expected-metrics.txt")


# ── JSON ทุกไฟล์ (เทียบ `jq empty`) ──
json_files = sorted(glob.glob(os.path.join(grafana_dir, '**', '*.json'), recursive=True))
if not json_files:
    err("ไม่พบไฟล์ .json ใต้ monitoring/grafana")
docs = {}
for f in json_files:
    try:
        with open(f, encoding='utf-8') as fh:
            docs[os.path.normpath(f)] = json.load(fh)
    except Exception as e:  # noqa: BLE001
        err(f"{os.path.relpath(f, grafana_dir)}: JSON ไม่ถูก ({e})")

# ── dashboard ──
dash_path = os.path.normpath(os.path.join(grafana_dir, 'dashboards', 'dormi-overview.json'))
d = docs.get(dash_path)
if d is None:
    err("ไม่พบ/อ่านไม่ได้ dashboards/dormi-overview.json")
else:
    if d.get('title') != 'Dormi ภาพรวม':
        err(f"dashboard title ต้องเป็น 'Dormi ภาพรวม' (ได้ {d.get('title')!r})")
    if d.get('uid') != 'dormi-overview':
        err("dashboard uid ต้องเป็น 'dormi-overview'")
    if d.get('id') is not None:
        err("dashboard id ต้องเป็น null (ให้ Grafana กำหนดเอง)")
    panels = []

    def walk(ps):
        for p in ps:
            panels.append(p)
            walk(p.get('panels', []))

    walk(d.get('panels', []))
    rows = [p for p in panels if p.get('type') == 'row']
    want_rows = ['ระบบปกติไหม', 'งานเบื้องหลัง', 'การใช้งานฟีเจอร์', 'ทรัพยากร']
    got_rows = [r.get('title') for r in rows]
    if got_rows != want_rows:
        err(f"แถวของ dashboard ต้องเป็น {want_rows} (ได้ {got_rows})")
    ids = [p.get('id') for p in panels]
    if len(ids) != len(set(ids)):
        err("panel id ซ้ำ")
    n_q = 0
    for p in panels:
        if p.get('type') == 'row':
            continue
        title = p.get('title', '')
        if not THAI.search(title):
            err(f"panel '{title}' ชื่อต้องเป็นภาษาไทย")
        for t in p.get('targets', []):
            ds = t.get('datasource') or p.get('datasource') or {}
            uid, expr = ds.get('uid'), t.get('expr', '')
            where = f"panel '{title}' query {t.get('refId')}"
            if uid in PROM_UIDS:
                check_prom(where, expr)
                n_q += 1
            elif uid in LOKI_UIDS:
                n_q += 1
                if '{' not in expr:
                    err(f"{where}: LogQL ไม่มี stream selector")
            else:
                err(f"{where}: datasource uid ไม่รู้จัก ({uid})")
    print(f"  dashboard: {len(panels) - len(rows)} panel, {len(rows)} แถว, {n_q} query")

# ── alert rules ──
alert_path = os.path.join(grafana_dir, 'alerts', 'dormi-alerts.yaml')
a = None
try:
    with open(alert_path, encoding='utf-8') as fh:
        a = yaml.safe_load(fh)
except Exception as e:  # noqa: BLE001
    err(f"alerts/dormi-alerts.yaml: YAML ไม่ถูกหรือไม่มีไฟล์ ({e})")
if a is not None:
    if a.get('apiVersion') != 1:
        err("alerts: apiVersion ต้องเป็น 1")
    uids, titles, n_rules = set(), set(), 0
    for g in a.get('groups', []):
        if g.get('folder') != 'Dormi':
            err(f"group {g.get('name')}: folder ต้องเป็น 'Dormi'")
        for r in g.get('rules', []):
            n_rules += 1
            t, u = r.get('title', ''), r.get('uid', '')
            if not THAI.search(t):
                err(f"rule '{t}': ชื่อต้องเป็นภาษาไทย")
            if u in uids:
                err(f"rule uid ซ้ำ: {u}")
            if t in titles:
                err(f"rule title ซ้ำ: {t}")
            uids.add(u)
            titles.add(t)
            if not re.fullmatch(r'dormi-[a-z0-9-]{1,30}', u):
                err(f"rule '{t}': uid '{u}' ต้องเป็น dormi-<ตัวเล็ก/ตัวเลข/ขีด>")
            for k in ('condition', 'data', 'noDataState', 'execErrState', 'for'):
                if k not in r:
                    err(f"rule '{t}': ขาด {k}")
            ann = r.get('annotations') or {}
            if not (ann.get('summary') and ann.get('description')):
                err(f"rule '{t}': ต้องมี annotations summary + description")
            for k in ('summary', 'description'):
                if ann.get(k) and not THAI.search(ann[k]):
                    err(f"rule '{t}': {k} ต้องเป็นภาษาไทย")
            refs = {q.get('refId') for q in r.get('data', [])}
            if r.get('condition') not in refs:
                err(f"rule '{t}': condition '{r.get('condition')}' ไม่มี refId นี้ใน data")
            for q in r.get('data', []):
                du, m = q.get('datasourceUid'), q.get('model', {})
                where = f"rule '{t}' query {q.get('refId')}"
                if du == '__expr__':
                    src = m.get('expression')
                    if src not in refs:
                        err(f"{where}: expression อ้าง '{src}' ที่ไม่มี")
                elif du in PROM_UIDS:
                    check_prom(where, m.get('expr', ''))
                elif du in LOKI_UIDS:
                    if '{' not in m.get('expr', ''):
                        err(f"{where}: LogQL ไม่มี stream selector")
                else:
                    err(f"{where}: datasourceUid ไม่รู้จัก ({du})")
    want = ['เว็บ/API ล่ม', 'ออกบิลรายวันไม่สำเร็จ', 'งานทุกนาทีหยุดรัน', 'backup ไม่สำเร็จ',
            'ดิสก์จะเต็ม', 'RAM ตึง', 'error พุ่ง', 'cert ใกล้หมด', 'DB connection ใกล้เต็ม']
    for w in want:
        if not any(t.startswith(w) for t in titles):
            err(f"ขาด alert '{w}'")
    print(f"  alerts: {n_rules} rule ใน {len(a.get('groups', []))} group")

# ── ไม่มี secret ในไฟล์ใต้ monitoring/ ──
pat = re.compile(r'glsa_[A-Za-z0-9_]{10,}|glc_[A-Za-z0-9+/=]{20,}|dop_v1_[0-9a-f]{20,}'
                 r'|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|Bearer\s+[A-Za-z0-9._-]{20,}')
mon_dir = os.path.normpath(os.path.join(grafana_dir, '..'))
for root, _, files in os.walk(mon_dir):
    for fn in files:
        p = os.path.join(root, fn)
        try:
            with open(p, encoding='utf-8') as fh:
                txt = fh.read()
        except Exception:  # noqa: BLE001
            continue
        if pat.search(txt):
            err(f"{os.path.relpath(p, mon_dir)}: พบรูปแบบที่เหมือน token/secret")

if errors:
    for e in errors:
        print("  ✗", e)
    sys.exit(1)
