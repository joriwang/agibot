#!/bin/bash
# Usage: ./move_cmd.sh [linear_x] [linear_y] [angular_z]
# Example: ./move_cmd.sh 0.2 0.0 0.5   (Forward 0.2m/s, Turn Left 0.5rad/s)
# Default: ./move_cmd.sh 0.2 0.0 0.0   (Forward 0.2m/s)

LIN_X=${1:-0.2}
LIN_Y=${2:-0.0}
ANG_Z=${3:-0.0}

echo "Publishing movement command: Linear X=$LIN_X, Linear Y=$LIN_Y, Angular Z=$ANG_Z"
echo "Press Ctrl+C to stop."

ros2 topic pub --rate 10 /cmd_vel_limiter geometry_msgs/msg/Twist "{linear: {x: $LIN_X, y: $LIN_Y, z: 0.0}, angular: {x: 0.0, y: 0.0, z: $ANG_Z}}"
