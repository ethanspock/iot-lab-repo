# IoT Lab (Docker + Portainer)

Deployable IoT/OT Lab environment containing:
- MQTT sensors
- Modbus wind farm
- BACnet power plant
- ThingsBoard telemetry
- Suricata + EveBox network monitoring

# Notes for Setup
Portainer will need to be manually initalized with the username and password prior to running bootstap.sh. Navigate to http://127.0.0.1:9000 and set the credentials then proceed with the bootstrap.sh to finish lab creation.

## Quick Start
```bash
git clone https://github.com/ethanspock/iot-lab-repo.git
cd iot-lab-repo
chmod +x install.sh bootstrap.sh
sudo ./install.sh
```

