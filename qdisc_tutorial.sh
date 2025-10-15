# NIC offloading
sudo ethtool -K enp0s8 gro off gso off tso off

# Replace directly qdisc
tc qdisc replace dev <interface> root fq_codel/pfifo/RED

# Return to the edefault qdisc
tc qdisc del dev enp0s8 root

# Show current qdisc
tc qdisc show dev enp0s8

# RED in normal case (bandwidth = 1Gbps)
tc qdisc replace dev enp0s8 root red limit 11000000 avpkt 1500 bandwidth 1gbit min 2500000 max 7500000 burst 1667 probability 0.02




| Tham số       | Ý nghĩa                                                  | Gợi ý giá trị (1 Gbps) |
| ------------- | -------------------------------------------------------- | ---------------------- |
| `limit`       | kích thước tối đa hàng đợi (byte)                        | ~ 300 KB               |
| `avpkt`       | kích thước trung bình gói                                | 1000 byte              |
| `bandwidth`   | băng thông của link                                      | 1 Gbps                 |
| `min`         | ngưỡng dưới bắt đầu tính drop                            | 20 KB                  |
| `max`         | ngưỡng trên, khi drop xác suất max đạt tới `probability` | 60 KB                  |
| `probability` | xác suất drop tối đa                                     | 0.02 (2%)              |



############## Limit bandwidth to 3Mbps ###############
# root = tbf (giới hạn băng thông)
sudo tc qdisc add dev enp0s8 root handle 1: tbf rate 3mbit burst 32kbit latency 50ms

# Add "DELAY JITTER LOSS"
sudo tc qdisc add dev enp0s8 parent 1: handle 10: netem delay 20ms 5ms loss 1%

# child = red để quản lý hàng đợi bên dưới tbf
sudo tc qdisc add dev enp0s8 parent 10: handle 20: red limit 30000 avpkt 1000 bandwidth 3mbit min 7500 max 22500 probability 0.02

# child = pfifo để quản lý hàng đợi bên dưới tbf
sudo tc qdisc add dev enp0s8 parent 10:20 handle 20: pfifo

################ No limit bandwidth #####################
sudo tc qdisc add dev enp0s9 root handle 10: netem delay 20ms 5ms loss 1%

# RED
sudo tc qdisc add dev enp0s9 parent 10: handle 20: red limit 11000000 avpkt 1500 bandwidth 1gbit min 2500000 max 7500000 burst 1667 probability 0.02

# PFIFO
sudo tc qdisc add dev enp0s9 parent 10:20 handle 20: pfifo