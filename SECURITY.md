# 安全问题报告

Markable 是**只读、离线**的本地应用：不发起网络请求、不修改源文件、不执行文档里的代码。
如果你发现安全问题（例如恶意 Markdown 触发的越权读取、导出路径穿越、链接 scheme 绕过），
请**不要开公开 Issue**，改用以下方式：

- GitHub 仓库的 **Security → Advisories → Report a vulnerability**（私密披露）；
- 或在 Issue 里只写「有安全问题，请提供私下渠道」，不要贴复现细节。

我们会在确认后尽快修复，并在发布说明里致谢（除非你希望匿名）。

已知的设计取舍（不是漏洞）：

- 导出 HTML 会内联本地图片为 `data:` URI；远程图片不会下载；
- 链接只允许 `http/https/mailto/tel/file/#/相对路径`，其余 scheme 会被降级为纯文字；
- `markable://` 仅接受本机文件路径，不接受远程 URL。
