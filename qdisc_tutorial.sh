# NIC offloading
sudo ethtool -K enp0s8 gro off gso off tso off

# Replace directly qdisc
tc qdisc replace dev <interface> root fq_codel/pfifo/RED

# Return to the edefault qdisc
tc qdisc del dev <interface> root

# Show current qdisc
tc qdisc show dev <interface>

# RED in normal case (bandwidth = 1Gbps)
tc qdisc replace dev enp0s9 root red limit 8000000 avpkt 1000 bandwidth 1gbit min 2500000 max 7500000 probability 0.02


| Tham số       | Ý nghĩa                                                  | Gợi ý giá trị (1 Gbps) |
| ------------- | -------------------------------------------------------- | ---------------------- |
| `limit`       | kích thước tối đa hàng đợi (byte)                        | ~ 300 KB               |
| `avpkt`       | kích thước trung bình gói                                | 1000 byte              |
| `bandwidth`   | băng thông của link                                      | 1 Gbps                 |
| `min`         | ngưỡng dưới bắt đầu tính drop                            | 20 KB                  |
| `max`         | ngưỡng trên, khi drop xác suất max đạt tới `probability` | 60 KB                  |
| `probability` | xác suất drop tối đa                                     | 0.02 (2%)              |


# RED in impairment case (bandwidth = 3Mbps, RTT = 20ms)
tc qdisc replace dev enp0s9 root red limit 30000 avpkt 1000 bandwidth 3mbit min 7500 max 22500 probability 0.02


# Limit bandwidth to 3Mbps
# root = tbf (giới hạn băng thông)
sudo tc qdisc add dev enp0s9 root handle 1: tbf rate 3mbit burst 32kbit latency 50ms

# child = red để quản lý hàng đợi bên dưới tbf
sudo tc qdisc add dev enp0s9 parent 1:1 handle 10: red limit 30000 avpkt 1000 bandwidth 3mbit min 7500 max 22500 probability 0.02

# child = pfifo để quản lý hàng đợi bên dưới tbf
sudo tc qdisc add dev enp0s9 parent 1:1 handle 10: pfifo