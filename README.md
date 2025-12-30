# IoT Lab (Docker + Portainer)

Deployable IoT/OT Lab environment containing:
- MQTT sensors
- Modbus wind farm
- BACnet power plant
- ThingsBoard telemetry
- Suricata + EveBox network monitoring

## Quick Start
```bash
git clone https://github.com/ethanspock/iot-lab-repo.git
cd iot-lab-repo
chmod +x install.sh bootstrap.sh
sudo ./install.sh
```
# Notes for Setup
## Portainer will need to be manually initalized with the user and password prior to running bootstap.sh navigate to http://127.0.0.1:9000 set the credentials and proceed with the bootstrap.sh
