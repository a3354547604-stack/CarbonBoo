"""服务端核心设施：配置、数据库、安全、错误码、限流。

分层约定（AGENTS §7.1「禁止跨层直连」的服务端等价物）：
    api（HTTP 契约） → services（业务） → models（持久化）
core 只被上层依赖，自身不依赖 api/services。
"""
