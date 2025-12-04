# launch/webrtc.launch.py
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node
from launch_ros.parameter_descriptions import ParameterValue


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument(
            "robot_id",
            default_value="6930e648e1c9963d56d36c3d",
            description="Unique ID of the robot"
        ),
        DeclareLaunchArgument(
            "signaling_url",
            default_value="ws://10.0.0.69:3000/signal",
            description="WebSocket URL of the signaling server"
        ),
        DeclareLaunchArgument(
            "auth_token",
            default_value="",
            description="Optional auth token for signaling server"
        ),
        DeclareLaunchArgument(
            "socketio_namespace",
            default_value="",
            description="Signaling server Socket.IO namespace"
        ),
        DeclareLaunchArgument(
            "ice_servers",
            default_value="['stun:stun.l.google.com:19302','turn:10.0.0.69?transport=udp','turn:10.0.0.69:3478?transport=tcp']",
            description="List of STUN/TURN URLs (YAML/JSON list or comma-separated string)"
        ),
        DeclareLaunchArgument(
            "ice_username",
            default_value="polyflow",
            description="Username for TURN servers (if required)"
        ),
        DeclareLaunchArgument(
            "ice_password",
            default_value="polyflow",
            description="Password for TURN servers (if required)"
        ),
        Node(
            package="webrtc",
            executable="webrtc_node",
            name="webrtc_client",
            output="screen",
            parameters=[{
                "robot_id": LaunchConfiguration("robot_id"),
                "signaling_url": LaunchConfiguration("signaling_url"),
                "auth_token": LaunchConfiguration("auth_token"),
                "socketio_namespace": LaunchConfiguration("socketio_namespace"),
                "ice_servers": ParameterValue(LaunchConfiguration("ice_servers"), value_type=str),
                "ice_username": ParameterValue(LaunchConfiguration("ice_username"), value_type=str),
                "ice_password": ParameterValue(LaunchConfiguration("ice_password"), value_type=str),
            }],
        ),
    ])
