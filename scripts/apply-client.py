#!/usr/bin/env python3
"""يطبّق إعدادات العميل (client.json) على نسخة الموقع المجهّزة للنشر.
الاستخدام:  python3 scripts/apply-client.py <مجلد-الموقع> <client.json>
يستبدل الرموز @@BRANCH1@@ و @@BRANCH2@@ بأسماء فروع العميل، ويفشل إن بقي أي رمز أو كان الاسم غير صالح."""
import json, os, re, sys

TOKENS = {'@@BRANCH1@@': 'branch1', '@@BRANCH2@@': 'branch2'}
BAD = re.compile(r"""[\\'"`$<>&@{}\n\r]""")

def main(site, cfg_path):
    cfg = json.load(open(cfg_path, encoding='utf-8'))
    values = {}
    for token, key in TOKENS.items():
        v = str(cfg.get(key, '')).strip()
        if not v or len(v) > 40 or BAD.search(v):
            sys.exit(f"client.json: قيمة '{key}' غير صالحة (فارغة أو طويلة أو فيها رموز ممنوعة)")
        values[token] = v
    if values['@@BRANCH1@@'] == values['@@BRANCH2@@']:
        sys.exit("client.json: اسما الفرعين لازم يكونا مختلفين")
    changed = 0
    for root, _, files in os.walk(site):
        for name in files:
            if not name.endswith(('.html', '.js', '.json')):
                continue
            path = os.path.join(root, name)
            with open(path, encoding='utf-8', newline='') as fh:
                text = fh.read()
            new = text
            for token, v in values.items():
                new = new.replace(token, v)
            if new != text:
                with open(path, 'w', encoding='utf-8', newline='') as fh:
                    fh.write(new)
                changed += 1
    left = []
    for root, _, files in os.walk(site):
        for name in files:
            if name.endswith(('.html', '.js', '.json')):
                with open(os.path.join(root, name), encoding='utf-8', errors='ignore') as fh:
                    if '@@BRANCH' in fh.read():
                        left.append(os.path.join(root, name))
    if left:
        sys.exit("رموز لم تُستبدل في: " + ", ".join(left))
    print(f"تم تطبيق إعدادات العميل على {changed} ملف")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
