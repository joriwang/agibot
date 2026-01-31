# Simulation Control Scripts

这个目录包含了用于替代手柄控制机器人的命令行脚本。
**注意**：使用前请确保仿真程序已启动，且已加载 `ROS2` 插件并正确配置了 `/cmd_vel_limiter` 话题的订阅后端。

## 目录
*   `set_zero_mode.sh`: 切换到 **Zero模式** (阻尼模式/初始化状态)。
*   `set_stand_mode.sh`: 切换到 **Stand模式** (站立状态)。
*   `set_walk_mode.sh`: 切换到 **Walk模式** (行走准备状态)。
*   `move_cmd.sh`: 发送移动指令。

## 使用流程

1.  **启动仿真**
    在 `build` 目录下运行 `./run_sim.sh`。

2.  **切换模式 (请严格按照顺序执行)**
    打开新终端，进入此目录：
    ```bash
    cd script/sim_control
    ```
    
    **步骤 A：初始化/复位**
    ```bash
    ./set_zero_mode.sh
    ```
    *观察：机器人可能会微调姿态。*

    **步骤 B：站立 (必须等待站稳)**
    ```bash
    ./set_stand_mode.sh
    ```
    *观察：机器人必须完全站立并保持稳定。请等待约 3-5 秒，确认站稳后再进行下一步。*
    *注意：如果机器人未站起或跌倒，请勿继续。*
    
    **步骤 C：进入行走模式**
    ```bash
    ./set_walk_mode.sh
    ```
    *观察：机器人可能会有原地踏步或调整重心的动作。*

3.  **控制移动**
    运行移动脚本，默认参数为向前以 0.2m/s 移动：
    ```bash
    ./move_cmd.sh
    ```
    
    也可以指定参数 `[Linear_X] [Linear_Y] [Angular_Z]`：
    ```bash
    # 向前 0.3m/s，同时向左转 0.2rad/s
    ./move_cmd.sh 0.3 0.0 0.2
    
    # 向后退 -0.2m/s
    ./move_cmd.sh -0.2
    ```
    
    按 `Ctrl+C` 停止发送指令。
