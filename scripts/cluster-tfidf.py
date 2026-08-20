#!/usr/bin/env python3
"""TF-IDF + average-linkage 階層式分群。A 路線的第一步：先分群，再看群裡有什麼。

只用標準庫，不拉 scikit-learn：TF-IDF 與 average-linkage 自己寫，比要求安裝
相依划算，而且分群結果要能重現 —— 相依版本變動會讓結果漂移，而重現性是這條
路線能不能跟 B 路線公平比較的前提。

決定性：token 排序固定、合併時 tie 用 (i, j) 的字典序決定，不依賴 dict
的插入順序或浮點數比較的偶然結果。

抽樣：語料是按 repo 依序 append 的，用等距抽樣（每隔 k 筆取一筆）而不是隨機
抽樣，保證抽樣完全決定性（不需要 seed），也保證每層最多 4 個來源 repo 全部
會被抽到，比隨機抽樣更能代表整層。k = 總數 // 上限，取第 1、1+k、1+2k…筆
（0-index 下即索引 0、k、2k…）。
"""
import argparse
import json
import math
import re
import sys
from collections import Counter

TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]{2,}")
STOP = {"the", "this", "that", "for", "are", "and", "not", "you", "但是", "這個", "可以"}


def tokenize(text):
    return [t.lower() for t in TOKEN.findall(text or "") if t.lower() not in STOP]


def cleanup_output(path):
    """Best-effort 刪除輸出檔案。若檔案不存在或刪除失敗，用 stderr 報告但不改變結束碼。"""
    import os
    if os.path.isfile(path):
        try:
            os.remove(path)
        except OSError as exc:
            print(f"WARNING\t清除舊輸出檔失敗（{path}）：{exc}", file=sys.stderr)


def load(path, output_path=None):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                print(f"LINE_PARSE_FAILED\t{path}\t第 {lineno} 行不是合法 JSON：{exc}",
                      file=sys.stderr)
                if output_path:
                    cleanup_output(output_path)
                sys.exit(1)
    return rows


def sample_evenly(rows, cap):
    """等距抽樣：k = 總數 // cap，取索引 0、k、2k…（對應「第 1、1+k、1+2k…筆」）。

    完全決定性、不需要 seed。語料按 repo 依序 append，每層最多 4 個來源
    repo，等距抽樣保證每個 repo 的區段都會被抽到，比隨機抽樣更能代表整層。

    只在 len(rows) > cap 時才觸發；k 用整數除法，len(rows) 剛好略高於 cap
    時 k 可能是 1（等於不抽樣），這是等距公式本身的邊界，不強行湊出恰好
    cap 筆的整數解。
    """
    total = len(rows)
    if total <= cap:
        return rows, total, total
    k = total // cap
    if k < 1:
        k = 1
    sampled = rows[::k]
    return sampled, total, len(sampled)


def tfidf(rows):
    docs = [tokenize((r.get("body") or "") + " " + (r.get("diff_hunk") or "")) for r in rows]
    df = Counter()
    for d in docs:
        df.update(set(d))
    vocab = sorted(df)  # 排序固定 → 向量維度順序可重現
    idx = {t: i for i, t in enumerate(vocab)}
    n = len(docs)
    vecs = []
    for d in docs:
        tf = Counter(d)
        v = {}
        for t, c in tf.items():
            v[idx[t]] = (c / len(d)) * math.log(n / (1 + df[t]))
        norm = math.sqrt(sum(x * x for x in v.values())) or 1.0
        vecs.append({k2: x / norm for k2, x in v.items()})
    return vecs, vocab


def cosine(a, b):
    if len(a) > len(b):
        a, b = b, a
    return sum(x * b.get(k, 0.0) for k, x in a.items())


def cluster(vecs, target):
    """average-linkage，合併到剩 target 群。

    tie 用 (i, j) 決定而不是「先遇到的」：浮點數相等在不同平台可能有不同的
    遍歷順序，那會讓同樣的輸入在不同機器上分出不同的群。全部文件 token
    完全相同時，每一對的 cosine 都恰好是 1.0（最極端的 tie），此時決定性
    完全靠 (a, b) 的穩定 id 字典序撐著。

    效能注記：brief 的參考實作在每一輪合併都對「目前所有群的所有配對」重新
    從頭算 group_sim——而 group_sim 本身是 O(|g1|*|g2|)。群平均大小隨合併
    次數增加而變大（到後期趨近 n/target），這個重複重算的乘法因子讓實測
    在 n=400 時就要 12.6 秒，外插到 n=2000（每層抽樣上限）落在 26 分鐘
    量級，四個大層合計超過 100 分鐘，跟 brief 原本「5 分鐘」的預期完全對
    不上。

    改用 Lance-Williams 遞增更新公式，數學上跟「合併後重新平均全部原始
    配對」完全等價（average-linkage／UPGMA 的標準恆等式，見下方推導），
    不是近似：
        group_sim(A∪B, C) = (|A|·group_sim(A,C) + |B|·group_sim(B,C)) / (|A|+|B|)
    推導：sum_{pairs(A∪B,C)} = sum_{pairs(A,C)} + sum_{pairs(B,C)}
                              = |A||C|·group_sim(A,C) + |B||C|·group_sim(B,C)
    除以 |A∪B|·|C| = (|A|+|B|)·|C| 即得上式。
    這讓每次合併後更新「新群對其他群」的相似度只需要 O(目前群數)，不必
    重新掃描群成員；改用穩定遞增 id（而不是清單位置）代表群，合併／刪除
    都不必重新索引。實測 n=2000 從外插的 26 分鐘降到數十秒量級（見
    task-3-report.md 的 Step 5 實測數字）。
    """
    n = len(vecs)
    next_id = n
    members = {i: [i] for i in range(n)}
    size = {i: 1 for i in range(n)}
    active = set(range(n))

    # D[(a, b)]（a < b）是目前還活著的兩個群之間的 average-linkage 相似度。
    # 起始值就是原始文件兩兩的 cosine similarity（單一文件群跟自己等價）。
    D = {}
    for i in range(n):
        for j in range(i + 1, n):
            D[(i, j)] = cosine(vecs[i], vecs[j])

    while len(active) > target:
        best, best_pair = None, None
        active_sorted = sorted(active)
        for ai in range(len(active_sorted)):
            a = active_sorted[ai]
            for b in active_sorted[ai + 1:]:
                s = D[(a, b)]
                if best is None or s > best or (s == best and (a, b) < best_pair):
                    best, best_pair = s, (a, b)
        a, b = best_pair

        c = next_id
        next_id += 1
        sa, sb = size[a], size[b]
        for x in active:
            if x == a or x == b:
                continue
            dax = D[(min(a, x), max(a, x))]
            dbx = D[(min(b, x), max(b, x))]
            D[(min(c, x), max(c, x))] = (sa * dax + sb * dbx) / (sa + sb)

        # a、b 的舊 pair 全部丟掉，記憶體只跟目前活著的群數平方成正比，
        # 不會隨合併次數無限累積。
        for x in active:
            D.pop((min(a, x), max(a, x)), None)
            D.pop((min(b, x), max(b, x)), None)
        D.pop((a, b), None)

        members[c] = sorted(members[a] + members[b])
        size[c] = sa + sb
        del members[a], members[b], size[a], size[b]
        active.discard(a)
        active.discard(b)
        active.add(c)

    groups = [members[g] for g in active]
    return sorted(groups, key=lambda g: (-len(g), g[0]))


def top_terms(group, vecs, vocab, k=6):
    agg = Counter()
    for i in group:
        for idx, w in vecs[i].items():
            agg[idx] += w
    return [vocab[i] for i, _ in agg.most_common(k)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--min-clusters", type=int, default=15)
    ap.add_argument("--max-clusters", type=int, default=40)
    ap.add_argument("--sample-cap", type=int, default=2000,
                     help="每層抽樣上限。average-linkage 是 O(n^3)，語料量大的層"
                          "跑不完，超過上限就等距抽樣。0 表示不抽樣。")
    args = ap.parse_args()

    if args.min_clusters < 1:
        print(f"INVALID_CLUSTER_BOUNDS\t{args.input}\t"
              f"min-clusters({args.min_clusters}) < 1",
              file=sys.stderr)
        cleanup_output(args.output)
        sys.exit(1)

    if args.min_clusters > args.max_clusters:
        print(f"INVALID_CLUSTER_BOUNDS\t{args.input}\t"
              f"min-clusters({args.min_clusters}) > max-clusters({args.max_clusters})",
              file=sys.stderr)
        cleanup_output(args.output)
        sys.exit(1)

    rows = load(args.input, args.output)
    if not rows:
        print(f"EMPTY_INPUT\t{args.input}\t沒有任何可分群的意見", file=sys.stderr)
        cleanup_output(args.output)
        sys.exit(1)

    if args.sample_cap > 0:
        rows, before_n, after_n = sample_evenly(rows, args.sample_cap)
        if after_n != before_n:
            print(f"SAMPLED\t{args.input}\t{before_n} 則 → 等距抽樣 → {after_n} 則",
                  file=sys.stderr)
        else:
            print(f"SAMPLED\t{args.input}\t{before_n} 則，未超過上限 {args.sample_cap}，未抽樣",
                  file=sys.stderr)

    # 每群至少要有 3 則才寫得出有出處的規則（spec：出處不足三則直接丟棄）。
    # 樣本數（抽樣後的實際筆數）撐不起下限群數時，硬切只會產出一堆註定被
    # 丟棄的群。
    if len(rows) < args.min_clusters * 3:
        print(f"TOO_FEW_SAMPLES\t{args.input}\t{len(rows)} 則撐不起 "
              f"{args.min_clusters} 群（每群至少 3 則）", file=sys.stderr)
        cleanup_output(args.output)
        sys.exit(1)

    vecs, vocab = tfidf(rows)
    target = max(args.min_clusters, min(args.max_clusters, len(rows) // 20))
    target = min(target, len(rows))
    groups = cluster(vecs, target)

    with open(args.output, "w", encoding="utf-8") as fh:
        for cid, g in enumerate(groups):
            fh.write(json.dumps({
                "cluster": cid,
                "n": len(g),
                "top_terms": top_terms(g, vecs, vocab),
                "members": [{
                    "html_url": rows[i].get("html_url"),
                    "path": rows[i].get("path"),
                    "body": rows[i].get("body"),
                    "diff_hunk": rows[i].get("diff_hunk"),
                } for i in g],
            }, ensure_ascii=False) + "\n")
    print(f"{args.input}\t{len(rows)} 則 → {len(groups)} 群")


if __name__ == "__main__":
    main()
