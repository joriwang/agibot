# ExampleProto 协议规格说明

> **源文件**: [`example_proto.proto`](file:///home/jori/Project/zhiyuan-x1-infer%20(copy)/src/protocols/example_proto/example_proto.proto)  
> **包名**: `xyber_x1_infer.example_proto`  
> **协议类型**: Protobuf (proto3)  
> **文档版本**: v1.0 | 2026-03-20

---

> [!CAUTION]
> **当前代码状态**：此文件为 **AimRT 框架占位模板**，消息名为 `change_me`，未在任何业务代码中使用。

## 1. 消息用途

AimRT 框架提供的 Protobuf 协议模板示例，用于开发者参考创建自定义 Protobuf 消息。**非生产协议**。

## 2. 消息定义 — `change_me`

| # | 字段名 | Protobuf 类型 | 字段编号 | 语义说明 | 单位 | 取值范围 | 备注 |
|---|--------|-------------|---------|---------|------|---------|------|
| 1 | `num` | `int32` | 1 | 占位字段 | — | -2³¹ ~ 2³¹-1 | 模板示例，无实际业务语义 |

## 3. 数据流

无。此消息未被任何模块发布或订阅。

## 4. 待确认事项

| 编号 | 事项 |
|------|------|
| P-EP-01 | 是否计划基于此模板开发实际 Protobuf 协议？ |
| P-EP-02 | 若不再需要，是否应从项目中移除以避免混淆？ |
