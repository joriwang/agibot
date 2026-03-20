# MyRosRpc 协议规格说明

> **源文件**: [`MyRosRpc.srv`](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/protocols/my_ros2_proto/srv/MyRosRpc.srv)  
> **包名**: `my_ros2_proto`  
> **协议类型**: ROS2 Service  
> **文档版本**: v1.0 | 2026-03-20

---

> [!WARNING]
> **当前代码状态**：此服务在 C++ 代码中**无任何引用**。可能为 AimRT ROS2 RPC 功能的预留接口或早期设计遗留。

## 1. 服务用途

通用 ROS2 RPC 服务定义，提供二进制数据请求 / 整型响应码的通信模式。[NEEDS VERIFICATION: 是否在生产环境中使用，或仅为 AimRT 框架模板]

## 2. 数据流

```
[NEEDS VERIFICATION]
客户端模块 ──── Request ────► 服务端模块
             ◄── Response ───
```

| 角色 | 模块 | 说明 |
|------|------|------|
| **客户端** | 未知 | [NEEDS VERIFICATION] 代码中未找到调用方 |
| **服务端** | 未知 | [NEEDS VERIFICATION] 代码中未找到服务注册 |

## 3. 字段定义

### 3.1 请求（Request）

| # | 字段名 | ROS2 类型 | 语义说明 | 单位 | 取值范围 | 备注 |
|---|--------|----------|---------|------|---------|------|
| 1 | `data` | `byte[]` | 请求载荷（二进制数据） | — | 任意字节序列 | 长度和编码格式由应用层定义 [NEEDS VERIFICATION] |

### 3.2 响应（Response）

| # | 字段名 | ROS2 类型 | 语义说明 | 单位 | 取值范围 | 备注 |
|---|--------|----------|---------|------|---------|------|
| 1 | `code` | `int64` | 响应状态码 | — | [NEEDS VERIFICATION] | 推测 0 = 成功，非 0 = 错误 |

## 4. 运行时特征

| 属性 | 值 | 说明 |
|------|-----|------|
| 调用模式 | 请求-响应（RPC） | 同步或异步取决于 AimRT RPC 配置 |
| 服务名称 | [NEEDS VERIFICATION] | — |
| 超时配置 | [NEEDS VERIFICATION] | — |

## 5. 待确认事项

| 编号 | 事项 |
|------|------|
| P-RPC-01 | 此服务是否已废弃？是否有计划在未来版本使用？ |
| P-RPC-02 | `data` 字段的编码格式和语义 |
| P-RPC-03 | `code` 字段的错误码定义 |
| P-RPC-04 | 客户端和服务端模块的确认 |
