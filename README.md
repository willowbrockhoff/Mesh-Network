# WilderMesh

WilderMesh is a self-contained communication network that works without cellular service or internet. Most communication systems require constant connectivity, so the focus of this project has been resilience and creating a system you can use when all the other infrastructure you typically rely on fails or doesn't exist. WilderMesh is a fully offline, decentralized, energy aware mesh network that will help keep you safe no matter the environment.  

To accomplish this, I created a system of small, portable nodes that communicate with each other through LoRa radio to create a reliable mesh network. Each node uses an ESP32 microcontroller with a Lora radio chip, as well as a GT-U7 GPS module.  

I also created an Android application that connects to nearby nodes using BLE, acting as an offline interface for users to monitor the network, check node's locations, and send alerts. Within the app you can scan for and connect to nearby nodes, view the node's location on an offline map, view nodes battery status, and a nodes current "mode" 

Nodes can operate in Normal, Low Power, or SOS mode. Low Power mode adjusts the node's behavior to be as energy efficient as possible. SOS mode alerts everyone within the network that this node is facing an emergency situation.   

Node's location can be viewed as GPS coordinates as well as a pin on an offline map. I built the offline map using vector tiles from OpenStreetMap and trimming them to Butte Co. using mbtile-extracts. The tiles are stored locally on the device to allow offline use.
