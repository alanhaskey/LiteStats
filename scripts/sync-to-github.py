#!/usr/bin/env python3
"""把本地 git 仓库通过 GitHub API 同步到远端（用于 github.com:443 被封、只能走 API 的场景）。

原理：GitHub 的 Git Data API 用的就是 git 的对象模型，同一份内容的 SHA 与本地一致，
所以「逐个上传 blob / tree / commit，最后把 ref 指过去」得到的 SHA 与本地完全相同 ——
可以直接用 SHA 是否相等来验证同步是否成功。

空仓库上 Git Data API 不可用（409），所以先用 Contents API 造一个引导提交，
最后把 main 强制指向本地 HEAD，引导提交就变成不可达的孤儿对象（不出现在任何分支历史里）。
"""
import base64
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

TOKEN = subprocess.check_output(["gh", "auth", "token"], text=True).strip()
OWNER = "alanhaskey"
REPO = "LiteStats"
BASE = f"https://api.github.com/repos/{OWNER}/{REPO}"
BRANCH = "main"

calls = 0


def api(method, path, payload=None, retries=5):
    global calls
    url = BASE + path
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": "litestats-sync",
    })
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                calls += 1
                return json.loads(response.read() or "{}")
        except urllib.error.HTTPError as error:
            detail = error.read().decode()[:400]
            # 次要速率限制 / 瞬时冲突：退避重试
            if error.code in (403, 429, 502, 503) and attempt < retries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            raise SystemExit(f"API 失败 {method} {path} -> {error.code}\n{detail}")
        except (urllib.error.URLError, TimeoutError):
            if attempt < retries - 1:
                time.sleep(2 * (attempt + 1))
                continue
            raise SystemExit(f"网络失败 {method} {path}")


def git(*args, binary=False):
    out = subprocess.run(["git", *args], capture_output=True, check=True).stdout
    return out if binary else out.decode()


# git 的身份行形如：yunnn <alanhaskey2013@qq.com> 1791609409 +0800
# 注意别用 rsplit(" ", 2) 拆 —— 名字里带空格时字段会错位（踩过），直接用正则。
IDENTITY = re.compile(r"^(.*) <([^>]*)> (\d+) ([+-]\d{4})$")


def parse_identity(value):
    match = IDENTITY.match(value)
    if not match:
        raise SystemExit(f"无法解析身份行：{value!r}")
    name, email, epoch, tz = match.groups()
    sign = -1 if tz.startswith("-") else 1
    offset = sign * (int(tz[1:3]) * 3600 + int(tz[3:5]) * 60)
    date = datetime.fromtimestamp(int(epoch), timezone(timedelta(seconds=offset))).isoformat()
    return {"name": name, "email": email, "date": date}


def parse_commit(sha):
    raw = git("cat-file", "commit", sha)
    head, _, message = raw.partition("\n\n")
    info = {"message": message}
    for line in head.splitlines():
        key, _, value = line.partition(" ")
        if key == "tree":
            info["tree"] = value
        elif key in ("author", "committer"):
            info[key] = parse_identity(value)
        elif key == "parent":
            info.setdefault("parents", []).append(value)
    return info


def parse_tag(ref):
    raw = git("cat-file", "tag", ref)
    head, _, message = raw.partition("\n\n")
    info = {"message": message}
    for line in head.splitlines():
        key, _, value = line.partition(" ")
        if key == "object":
            info["object"] = value
        elif key == "tag":
            info["tag"] = value
        elif key == "tagger":
            info["tagger"] = parse_identity(value)
    return info


# ---------------------------------------------------------------- 引导提交

print("==> 1/6 引导提交（空仓库上 Git API 不可用）")
try:
    api("GET", "/contents/.bootstrap")
    print("    已有引导提交，跳过")
except SystemExit:
    api("PUT", "/contents/.bootstrap", {
        "message": "chore: 初始化仓库",
        "content": base64.b64encode(b"bootstrap\n").decode(),
    })

# ---------------------------------------------------------------- blob

commits = git("rev-list", "--reverse", "HEAD").split()
print(f"==> 2/6 上传 blob（{len(commits)} 个提交的内容）")

# 每个提交的完整树（含子目录），按提交顺序取，保证父提交的对象先存在
blob_cache, tree_cache = set(), {}
commit_trees = {}
for sha in commits:
    entries = []
    for line in git("ls-tree", "-r", "-t", sha).splitlines():
        meta, _, path = line.partition("\t")
        mode, kind, obj = meta.split()
        entries.append((path, mode, kind, obj))
    commit_trees[sha] = entries

all_blobs = {obj for entries in commit_trees.values() for _, _, kind, obj in entries if kind == "blob"}
print(f"    去重后 {len(all_blobs)} 个 blob")
for index, obj in enumerate(sorted(all_blobs), 1):
    if obj in blob_cache:
        continue
    content = git("cat-file", "blob", obj, binary=True)
    result = api("POST", "/git/blobs",
                 {"content": base64.b64encode(content).decode(), "encoding": "base64"})
    if result["sha"] != obj:
        raise SystemExit(f"blob SHA 不一致：本地 {obj} vs 远端 {result['sha']}")
    blob_cache.add(obj)
    if index % 50 == 0:
        print(f"    {index}/{len(all_blobs)}")

# ---------------------------------------------------------------- tree

print("==> 3/6 上传 tree（自底向上）")

# ⚠️ 缓存必须按"本地 tree SHA"做键（内容寻址），不能按路径名 ——
# 按路径名会让后面的提交引用到上一个提交的同名子树（踩过）。
tree_cache = {}


def build_tree(local_tree_sha):
    if local_tree_sha in tree_cache:
        return tree_cache[local_tree_sha]
    items = []
    for line in git("ls-tree", local_tree_sha).splitlines():
        meta, _, name = line.partition("\t")
        mode, kind, obj = meta.split()
        if kind == "tree":
            items.append({"path": name, "mode": mode, "type": "tree",
                          "sha": build_tree(obj)})
        else:
            items.append({"path": name, "mode": mode, "type": "blob", "sha": obj})
    # git 的树条目排序：目录按"名字+/"比较
    def sort_key(item):
        suffix = "/" if item["type"] == "tree" else ""
        return (item["path"] + suffix).encode()

    result = api("POST", "/git/trees", {"tree": sorted(items, key=sort_key)})["sha"]
    if result != local_tree_sha:
        raise SystemExit(f"tree SHA 不一致：本地 {local_tree_sha} vs 远端 {result}")
    tree_cache[local_tree_sha] = result
    return result


for index, sha in enumerate(commits, 1):
    build_tree(parse_commit(sha)["tree"])
    if index % 5 == 0:
        print(f"    {index}/{len(commits)} 个提交的 tree")
print(f"    共 {len(tree_cache)} 棵不重复的 tree")

print("==> 4/6 建立提交链")
remote_commits = {}
for sha in commits:
    info = parse_commit(sha)
    payload = {
        "message": info["message"],
        "tree": info["tree"],
        "author": info["author"],
        "committer": info["committer"],
    }
    if info.get("parents"):
        payload["parents"] = [remote_commits[parent] for parent in info["parents"]]
    result = api("POST", "/git/commits", payload)
    if result["sha"] != sha:
        raise SystemExit(f"commit SHA 不一致：本地 {sha} vs 远端 {result['sha']}")
    remote_commits[sha] = result["sha"]
head = remote_commits[commits[-1]]
print(f"    HEAD {head}")

# ---------------------------------------------------------------- ref

print("==> 5/6 把 main 指向本地 HEAD（引导提交变成不可达）")
api("PATCH", f"/git/refs/heads/{BRANCH}", {"sha": head, "force": True})

# ---------------------------------------------------------------- tags

print("==> 6/6 同步 tag")
try:
    existing_refs = {item["ref"] for item in api("GET", "/git/refs/tags")}
except SystemExit:
    existing_refs = set()
for ref in git("tag", "-l").split():
    info = parse_tag(ref)
    tag_obj = api("POST", "/git/tags", {
        "tag": info["tag"],
        "message": info["message"],
        "object": remote_commits.get(info["object"], info["object"]),
        "type": "commit",
        "tagger": info["tagger"],
    })
    full = f"refs/tags/{ref}"
    if full in existing_refs:
        api("PATCH", f"/git/refs/tags/{ref}", {"sha": tag_obj["sha"], "force": True})
        print(f"    {ref} 已存在 → 更新为 {tag_obj['sha'][:10]}")
    else:
        api("POST", "/git/refs", {"ref": full, "sha": tag_obj["sha"]})
        print(f"    {ref} 新建 -> {tag_obj['sha'][:10]}")

print(f"\n完成，共 {calls} 次 API 调用；远端 HEAD = {head}")
