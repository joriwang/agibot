#!/bin/bash
echo "Switching to Stand Mode..."
ros2 topic pub --once /stand_mode std_msgs/msg/Float32 "{data: 1.0}"
