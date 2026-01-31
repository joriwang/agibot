#!/bin/bash
echo "Switching to Walk Mode..."
ros2 topic pub --once /walk_mode std_msgs/msg/Float32 "{data: 0.0}"
