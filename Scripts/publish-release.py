import hashlib, json, os, pathlib, re, stat, subprocess, tempfile, zipfile
from urllib.parse import quote

def check(ok, message):
    if not ok:
        raise RuntimeError(message)

def api(path, method='GET', data=None, missing=False):
    args = ['gh', 'api', '--method', method, path]
    if data is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=None if data is None else json.dumps(data), capture_output=True, text=True)
    if result.returncode:
        if missing and '(HTTP 404)' in result.stderr:
            return None
        raise RuntimeError(f'{method} {path} failed (gh exit {result.returncode})')
    return json.loads(result.stdout) if result.stdout.strip() else None

repo, sha, run = os.environ['GITHUB_REPOSITORY'], os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID'])
base = f'repos/{repo}'
check(repo == 'wm0104/irisin' and os.environ['GITHUB_REF'] == 'refs/heads/test', 'Wrong repository or branch')
check(os.environ['GITHUB_EVENT_NAME'] in ('push', 'workflow_dispatch') and re.fullmatch('[0-9a-f]{40}', sha), 'Wrong event or SHA')
attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
workflow_run = api(f'{base}/actions/runs/{run}')
check(workflow_run['repository']['full_name'] == repo and workflow_run['head_repository']['full_name'] == repo, 'Workflow repository mismatch')
check(workflow_run['head_sha'] == sha and workflow_run['head_branch'] == 'test' and workflow_run['event'] == os.environ['GITHUB_EVENT_NAME'] and workflow_run['path'] == '.github/workflows/ci.yml' and workflow_run['run_attempt'] == attempt, 'Workflow identity mismatch')
jobs = api(f'{base}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100')['jobs']
for name in ('Host tests', 'Build and verify iphoneos-arm64e'):
    matches = [job for job in jobs if job['name'] == name]
    check(len(matches) == 1 and matches[0]['status'] == 'completed' and matches[0]['conclusion'] == 'success', f'{name} did not succeed')
version_text = pathlib.Path('Configuration/Version.xcconfig').read_text()
versions = re.findall(r'^MARKETING_VERSION\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$', version_text, re.M)
check(len(versions) == 1, 'Expected one source version')
version, tag = versions[0], 'v' + versions[0] + '-test'

def current_head():
    check(api(f'{base}/git/ref/heads/test')['object']['sha'] == sha, 'test moved; refusing obsolete publisher writes')

def release_for_tag():
    found = api(f'{base}/releases/tags/{tag}', missing=True)
    if found is not None:
        return found
    # The tag endpoint can omit drafts; authenticated listing must also be checked.
    page = 1
    while True:
        releases = api(f'{base}/releases?per_page=100&page={page}')
        for candidate in releases:
            if candidate['tag_name'] == tag:
                return candidate
        if len(releases) < 100:
            return None
        page += 1

release = release_for_tag()
if release is not None:
    check(not release['draft'] and release.get('published_at'), 'Existing release is not public; refusing to modify it')

def resolved_commit(ref):
    if ref is None:
        return None
    obj = ref['object']
    for _ in range(8):
        if obj['type'] != 'tag':
            break
        obj = api(f"{base}/git/tags/{obj['sha']}")['object']
    check(obj['type'] == 'commit' and re.fullmatch('[0-9a-f]{40}', obj['sha']), 'Tag does not resolve to a commit')
    return obj['sha']

def check_tag(require_current=False):
    ref = api(f'{base}/git/ref/tags/{tag}', missing=True)
    commit = resolved_commit(ref)
    if require_current:
        check(commit == sha, 'Tag does not resolve to this commit')
    return ref

def latest_release():
    latest = api(f'{base}/releases/latest', missing=True)
    if latest is not None:
        match = re.fullmatch(r'v([0-9]+\.[0-9]+\.[0-9]+)-test', latest.get('tag_name', ''))
        check(match is not None and latest.get('name') == f'Irisin {match[1]}' and not latest.get('draft') and latest.get('published_at'), 'Latest release version is not trustworthy')
        result = subprocess.run(['dpkg', '--compare-versions', package_version, 'ge', match[1]])
        check(result.returncode == 0, 'DEB version is below Latest or cannot be compared')
    return latest


def automatic_notes(release, old_ref, latest):
    marker = '<!-- irisin-auto-release -->'
    heading = f'# Irisin {version} 更新内容'
    anchor = resolved_commit(old_ref)
    previous = '' if release is None else release.get('body') or ''
    entry = re.compile(r'^- .+ \[([0-9a-f]{7})\]\(https://github\.com/wm0104/irisin/commit/([0-9a-f]{40})\)$')
    previous_lines, previous_shas = [], set()
    if previous.startswith(marker + '\n' + heading + '\n'):
        for line in previous.splitlines():
            matched = entry.fullmatch(line)
            if matched:
                check(matched[2].startswith(matched[1]), 'Previous notes SHA mismatch')
                if matched[2] not in previous_shas:
                    previous_lines.append(re.sub(r'\\([\\`*_{}\[\]<>])', r'\1', line[2:].rsplit(' [', 1)[0]))
                    previous_shas.add(matched[2])
    elif previous and not previous.startswith(marker):
        previous_lines = list(dict.fromkeys(line for line in previous.splitlines() if line.strip()))
    if anchor is None and latest is not None:
        prior_tag = latest['tag_name']
        anchor = resolved_commit(api(f'{base}/git/ref/tags/{quote(prior_tag, safe="")}', missing=True))
    commits, reset = [], False
    main = '39242846e35fb60740a6fb3a3940dd24bb9769c3'
    if anchor == sha:
        # A failed final body write can leave the moved tag with pre-squash notes.
        build = api(f'{base}/commits/{sha}')
        if build['commit']['message'].split('\n', 1)[0] == '添加配置备份，简化安装卸载流程':
            check(build['sha'] == sha and len(build.get('parents', [])) == 1 and build['parents'][0]['sha'] == main, 'Untrusted history rewrite parents')
            anchor, reset = main, True
    if anchor is not None and anchor != sha:
        page, total = 1, None
        while total is None or len(commits) < total:
            compared = api(f'{base}/compare/{anchor}...{sha}?per_page=100&page={page}')
            if page == 1 and compared['status'] in ('diverged', 'behind'):
                # Only the explicitly authorized one-child history rewrite may reset notes.
                build = api(f'{base}/commits/{sha}')
                check(build['sha'] == sha and len(build.get('parents', [])) == 1 and build['parents'][0]['sha'] == main, 'Untrusted history rewrite parents')
                check(build['commit']['message'].split('\n', 1)[0] == '添加配置备份，简化安装卸载流程', 'Untrusted history rewrite title')
                anchor, reset = main, True
                compared = api(f'{base}/compare/{anchor}...{sha}?per_page=100&page=1')
            if reset:
                check(compared['total_commits'] == 1, 'History rewrite is not one child of main')
            check(compared['status'] == 'ahead', 'Previous release is not an ancestor of this build')
            if total is None:
                total = compared['total_commits']
            check(compared['total_commits'] == total and compared['commits'], 'Incomplete commit comparison')
            commits.extend(compared['commits'])
            check(len(commits) <= total, 'Unexpected compare pagination')
            page += 1
        check(commits[-1]['sha'] == sha, 'Comparison does not reach build SHA')
    else:
        commits = [api(f'{base}/commits/{sha}')]
    seen = set()
    lines = [] if reset else previous_lines.copy()
    accumulated = set() if reset else previous_shas.copy()
    for commit in commits:
        commit_sha = commit['sha']
        check(re.fullmatch('[0-9a-f]{40}', commit_sha) and commit_sha not in seen, 'Invalid or duplicate commit')
        seen.add(commit_sha)
        subject = commit['commit']['message'].split('\n', 1)[0].strip()
        check(subject, 'Empty commit subject')
        if commit_sha not in accumulated and subject not in lines:
            lines.append(subject)
            accumulated.add(commit_sha)
    check(seen, 'Empty automatic release notes')
    return '\n'.join(lines)

check_tag()
artifact_id = os.environ['ARTIFACT_ID']
check(artifact_id.isdigit(), 'Missing upload artifact ID')
artifact = api(f'{base}/actions/artifacts/{artifact_id}')
check(artifact['id'] == int(artifact_id) and not artifact['expired'], 'Invalid artifact ID or expired artifact')
check(artifact['workflow_run']['id'] == run and artifact['workflow_run']['head_sha'] == sha, 'Artifact belongs to another run or commit')
check(artifact['name'] == f'irisin-{sha}', 'Unexpected artifact name')
upload_digest = os.environ['ARTIFACT_DIGEST'].removeprefix('sha256:')
check(re.fullmatch('[0-9a-f]{64}', upload_digest) is not None, 'Missing upload digest')
check(artifact.get('digest') == 'sha256:' + upload_digest, 'Artifact metadata differs from upload digest')
filename = f'wiki.qaq.irisin_{version}_iphoneos-arm64e.deb'
with tempfile.TemporaryDirectory(prefix='irisin-release-') as temporary:
    folder = pathlib.Path(temporary)
    archive = folder / 'artifact.zip'
    with archive.open('wb') as output:
        result = subprocess.run(['gh', 'api', '--method', 'GET', '--allow-escape-sequences', f'{base}/actions/artifacts/{artifact_id}/zip'], stdout=output, stderr=subprocess.PIPE)
    check(result.returncode == 0, f'GET {base}/actions/artifacts/{artifact_id}/zip failed')
    check(archive.stat().st_size == artifact['size_in_bytes'], 'Artifact ZIP size mismatch')
    check(hashlib.sha256(archive.read_bytes()).hexdigest() == upload_digest, 'Artifact ZIP digest mismatch')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        check(len(entries) == 1 and entries[0].filename == filename, 'Expected exactly the versioned DEB, without extra entries')
        mode = entries[0].external_attr >> 16
        check(not entries[0].is_dir() and stat.S_IFMT(mode) in (0, stat.S_IFREG) and entries[0].file_size > 0, 'DEB ZIP entry is not a regular nonempty file')
        check(zipped.testzip() is None, 'Artifact CRC mismatch')
        package = folder / filename
        package.write_bytes(zipped.read(entries[0]))
    for field, expected in [('Package', 'wiki.qaq.irisin'), ('Version', version), ('Architecture', 'iphoneos-arm64e')]:
        actual = subprocess.check_output(['dpkg-deb', '-f', str(package), field], text=True).strip()
        check(actual == expected, f'DEB {field} mismatch')
        if field == 'Version':
            package_version = actual
    digest, size = 'sha256:' + hashlib.sha256(package.read_bytes()).hexdigest(), package.stat().st_size
    # Keep metadata before any remote write. CI retains it even on failure.
    current_head()
    release = release_for_tag()
    if release is not None:
        check(not release['draft'] and release.get('published_at'), 'Existing release is not public')
    tag_ref = check_tag()
    # Resolve the previous source and generate nonempty notes before any tag move.
    latest = latest_release()
    body = automatic_notes(release, tag_ref, latest)
    check(body.strip(), 'Empty automatic release notes')
    old_assets = [] if release is None else api(f'{base}/releases/{release["id"]}/assets')
    check(len(old_assets) <= 1 and all(a['name'] == filename for a in old_assets), 'Unexpected existing assets; refusing destructive cleanup')
    evidence = pathlib.Path(os.environ['RUNNER_TEMP']) / 'irisin-release-evidence'
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'before.json').write_text(json.dumps({'release': release, 'tag': tag_ref, 'assets': old_assets, 'sha': sha, 'run': run, 'attempt': attempt}, ensure_ascii=False, indent=2))

    def move_tag():
        current_head()
        if tag_ref is None:
            api(f'{base}/git/refs', 'POST', {'ref': 'refs/tags/' + tag, 'sha': sha})
        else:
            api(f'{base}/git/refs/tags/{tag}', 'PATCH', {'sha': sha, 'force': True})
        check(check_tag(True) is not None, 'Release tag is missing')

    def verify_asset(asset, name):
        check(asset['name'] == name and asset['size'] == size and asset.get('digest') == digest and asset['state'] == 'uploaded', 'Asset integrity mismatch')
        downloaded = folder / 'uploaded.deb'
        with downloaded.open('wb') as output:
            result = subprocess.run(['gh', 'api', '--method', 'GET', f'{base}/releases/assets/{asset["id"]}', '-H', 'Accept: application/octet-stream'], stdout=output, stderr=subprocess.PIPE)
        check(result.returncode == 0 and downloaded.stat().st_size == size and 'sha256:' + hashlib.sha256(downloaded.read_bytes()).hexdigest() == digest, 'Uploaded asset bytes mismatch')

    existing = release is not None
    if not existing:
        move_tag()
        current_head()
        payload = {'tag_name': tag, 'name': f'Irisin {version}', 'body': body, 'draft': True, 'prerelease': False}
        release = api(f'{base}/releases', 'POST', payload)
        check(release['draft'] and release['tag_name'] == tag, 'Unexpected draft response')
    # Public updates cannot be atomic. Upload and verify before touching the old DEB.
    upload_name = filename + f'.pending-{run}-{attempt}' if existing else filename
    current_head()
    upload_url = release['upload_url'].split('{', 1)[0] + '?name=' + quote(upload_name)
    result = subprocess.run(['gh', 'api', '--method', 'POST', upload_url, '-H', 'Content-Type: application/vnd.debian.binary-package', '--input', str(package)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    check(result.returncode == 0, f'POST release {release["id"]} asset upload failed')
    assets = api(f'{base}/releases/{release["id"]}/assets')
    uploaded = [a for a in assets if a['name'] == upload_name]
    check(len(uploaded) == 1 and len(assets) == len(old_assets) + 1, 'Unexpected uploaded assets')
    verify_asset(uploaded[0], upload_name)
    if existing:
        move_tag()
        for old in old_assets:
            current_head()
            api(f'{base}/releases/assets/{old["id"]}', 'DELETE')
        current_head()
        renamed = api(f'{base}/releases/assets/{uploaded[0]["id"]}', 'PATCH', {'name': filename})
        verify_asset(renamed, filename)
    assets = api(f'{base}/releases/{release["id"]}/assets')
    check(len(assets) == 1, 'Expected exactly one published DEB')
    verify_asset(assets[0], filename)
    current_head()
    public = api(f'{base}/releases/{release["id"]}', 'PATCH', {'name': f'Irisin {version}', 'draft': False, 'prerelease': False, 'body': body, 'make_latest': 'true'})
    check(not public['draft'] and public['body'] == body and public['tag_name'] == tag and public['name'] == f'Irisin {version}' and not public['prerelease'], 'Publication response mismatch')
    check(check_tag(True) is not None, 'Published tag is missing')
    current_head()
    latest = api(f'{base}/releases/latest')
    check(latest['id'] == release['id'] and latest['tag_name'] == tag and not latest['draft'] and latest['body'] == body, 'Latest release mismatch')
    (evidence / 'after.json').write_text(json.dumps({'release': latest, 'tag': check_tag(True), 'assets': assets}, ensure_ascii=False, indent=2))
    print(f'Published {tag}: {filename}, {digest}')
