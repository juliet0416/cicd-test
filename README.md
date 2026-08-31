# Chat2DB Desktop CI/CD

本仓库负责 Chat2DB Pro 和 Chat2DB Local 桌面安装包、自动更新资源及发布指针。

## Workflows

| 产品 | Workflow | 更新根目录 |
| --- | --- | --- |
| Pro | `.github/workflows/pro.yml` | `download/` |
| Local | `.github/workflows/local.yml` | `offline/` |

触发分支决定使用哪一版 CICD 脚本；`source_ref` 决定使用哪个 Chat2DB Studio 分支、Tag 或 SHA。测试分支时两者都必须显式填写，`source_ref` 留空会回退到仓库 Secret 配置的默认源码分支。

## releaseEpoch

`releaseEpoch` 是桌面 V2 自动更新使用的单调递增发布序号，不是软件版本号、时间戳、数据 Schema 版本或 updater protocol 版本。客户端只接受同时满足以下条件的目标：

```text
target.version > installed.version
target.releaseEpoch > installed.releaseEpoch
```

### 人工取值规则

每次触发 V2 打包或发布前，由操作人手动读取目标产品的 Stable 和 Beta 线上 Index：

```bash
# Pro
curl --compressed -fsSL 'https://cdn.chat2db-ai.com/download/updates-v2/stable/latest_version.json' \
  | jq '{channel, releaseEpoch}'
curl --compressed -fsSL 'https://cdn.chat2db-ai.com/download/updates-v2/beta/latest_version.json' \
  | jq '{channel, releaseEpoch}'

# Local
curl --compressed -fsSL 'https://cdn.chat2db-ai.com/offline/updates-v2/stable/latest_version.json' \
  | jq '{channel, releaseEpoch}'
curl --compressed -fsSL 'https://cdn.chat2db-ai.com/offline/updates-v2/beta/latest_version.json' \
  | jq '{channel, releaseEpoch}'
```

规则：

1. Pro 和 Local 分别计算，不能互相借用 epoch。
2. 同一产品取 Stable/Beta 中最大的线上 `releaseEpoch`，新发布手动填写 `max + 1`。
3. 不存在的 Index 不参与比较；无法读取或结果不确定时不得猜测、不得触发正式发布。
4. Action 输入和历史日志只用于审计，不是已发布状态的权威来源。
5. `update_latest_version_json=false` 的测试 Action 没有更新线上指针，不占用新的 epoch；同一候选可以继续使用原值重试。
6. 正式发布前必须重新读取一次线上 Index，确认期间没有其他发布推进 epoch。
7. 安装包 `version.json`、平台 Manifest 和频道 Index 必须使用同一个 epoch。

当前过渡基线：

```text
Pro 5.3.3: releaseEpoch=0
Pro 5.3.4: releaseEpoch=1
Pro Beta current maximum: releaseEpoch=4
Pro 5.3.5 protocol-2 transition candidate: releaseEpoch=5
```

后续版本不能仅根据版本号写死 epoch。例如先发布 Beta 后再发布 Stable，Stable 必须继续使用线上最大 epoch 的下一个值。

## 参数

| 参数 | 含义 |
| --- | --- |
| `version` | 应用 SemVer，例如 `5.3.5` |
| `publish_mode` | `v1`、`v2` 或 `both` |
| `source_ref` | Studio 分支、Tag 或完整 SHA |
| `channel` | `stable` 或 `beta` |
| `release_epoch` | 按上述规则人工读取并传入 |
| `upload_latest` | 是否更新公开 latest 安装包别名 |
| `update_latest_version_json` | 是否更新自动更新指针 |
| `release_notes_url` | HTTPS Release Notes 地址 |

## 测试打包

测试包不更新 latest 安装包别名和自动更新指针，但仍可能上传版本目录下的构建产物：

```bash
gh workflow run pro.yml \
  --repo juliet0416/cicd-test \
  --ref '<cicd-ref>' \
  -f logLevel=warning \
  -f version='<version>' \
  -f publish_mode=v2 \
  -f source_ref='<studio-ref>' \
  -f upload_latest=false \
  -f update_latest_version_json=false \
  -f channel=stable \
  -f release_epoch='<manually-resolved-epoch>' \
  -f release_notes_url=https://chat2db.ai/release-notes
```

## 正式发布

正式发布前重新读取线上 Stable/Beta Index。只有所有目标平台、签名、上传和 promotion 检查通过后，才允许将下面两个开关设为 `true`：

```text
upload_latest=true
update_latest_version_json=true
```

发布完成后再次读取线上 Index，确认 `releaseEpoch`、版本、频道和目标 Manifest 已更新为本次发布值。

## Pro 5.3.5 Transition

Pro 5.3.5 是一次性 protocol 2 入站兼容版本：

- `release_epoch=5`（2026-08-31 手动读取 Stable=1、Beta=4 后取最大值加 1）
- `publish_mode=v2`
- 目标包为 `bridge-fat`
- 5.3.3/5.3.4 原生安装器使用各自 rollback package
- 测试阶段保持 `upload_latest=false`、`update_latest_version_json=false`

该过渡发布完成并经过真实升级验证后，5.3.6+ 只保留 protocol 3 发布路径。
