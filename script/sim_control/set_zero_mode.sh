#!/bin/bash
echo "Switching to Zero Mode (Damping)..."
ros2 topic pub --once /zero_mode std_msgs/msg/Float32 "{data: 1.0}"
