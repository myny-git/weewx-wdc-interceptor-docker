# weewx-wdc-interceptor-docker
This is my own dockerfile, forked from Daveiano! Many thanks to him, as now, I am running the newest versions of [weewx](https://github.com/weewx/weewx) on my synology NAS. I also run the [interceptor](https://github.com/matthewwall/weewx-interceptor) driver and following extensions: [weewx-forecast](https://github.com/chaunceygardiner/weewx-forecast/) extension, [weewx-wdc](https://github.com/Daveiano/weewx-wdc), [weewx-xcumulative](https://github.com/gjr80/weewx-xcumulative), [weewx-xaggs](https://github.com/tkeffer/weewx-xaggs),
[weewx-GTS](https://github.com/roe-dl/weewx-GTS).

These are the things I did to get it working:

My weather station (Bresser WIFI 5in1 pro) unfortunately did not allow for a direct connection to a home server, but it does allow for an upload to Wunderground. I created an account, and completed the details and from then onwards, my station is sending data to Wunderground. But, I still wanted to capture the traffic for using in my home assistant. That's why in my ASUS router with Merlin firmware, I created some IP-tables to redirect the traffic to Wunderground to my WeeWx server:

iptables -t nat -A PREROUTING -s bresserIP -p tcp --dport 80 -j DNAT --to-destination weewx-serverIP:3010 
iptables -t nat -A POSTROUTING -j MASQUERADE  

Now all packets will be redirected to port 3010.

Then I installed this docker container on my synology via docker-compose. The interceptor is used in the listen mode. This is the docker-compose file. The tags of the image will change depending on install and use. As you can see, the docker is listening to port 9877, which I redirected to port 3010. There is also on nginx service included, for the website.

```
version: "3.7"

services:
  weewx-python:
    container_name: weewx_bresser
#    build: .
    image: mynygit/weewxv5_docker:5.1.0
    ports:
      - 3010:9877
    volumes:
      - weewx-db:/home/weewx-data/archive
      - weewx-html:/home/weewx-data/public_html
      - /linktomydockerdata/:/home/weewx-data/data
    restart: unless-stopped
  weewx-web:
    container_name: weewx_bresser_web
    image: nginx:latest
    ports:
      - 8014:80
    volumes:
      - weewx-html:/usr/share/nginx/html

volumes:
  weewx-db:
  weewx-html:
```

Then, for the interceptor driver inweewx.conf:

```
[Interceptor]
    # This section is for the network traffic interceptor driver.

    # The driver to use:
    driver = user.interceptor
    device_type = wu-client   #### this is used for all undefined clients which just upload to Wunderground.
    mode = listen
    address = 0.0.0.0
    port = 3010
Kris_bresser's profile photo
Kris_bresser
Jul 31, 2024, 10:49:09 AM (5 days ago) 
to weewx-user
Hi all

I am enjoying a lot my Bresser Wifi Pro 5in1 weather station and I am pushing the data into my home assistant via the WeeWX docker. I first explain a bit how I did it, as it may help users with similar hardware, but at the end, I do have a question.

These are the things I did to get it working:

My weather station unfortunately did not allow for a direct connection to a home server, but it does allow for an upload to Wunderground. I created an account, and filled out the details and from then onwards, my station is sending data to Wunderground. But, I still wanted to capture the traffic for using in my home assistant. That's why in my ASUS router with Merlin firmware, I created some IP-tables to redirect the traffic to Wunderground to my WeeWx server:
 iptables -t nat -A PREROUTING -s bresserIP -p tcp --dport 80 -j DNAT --to-destination weewx-serverIP:3010 
iptables -t nat -A POSTROUTING -j MASQUERADE  

Now all packets will be redirected to port 3010.

Then I installed a docker container on my synology via docker-compose. The docker is from felddy, weewx. This combines MQTT,  weewx and the interceptor, as I am redirecting traffic.
--------------------------
version: "3.8"
services:
  weewx:
    container_name: weewx_bresser
    image: felddy/weewx
    init: true
    restart: "always"
    privileged: true
    network_mode: host    
    ports:
       - 8102:80
    volumes:
       - /volume1/docker/weewx/:/data
      - /volume1/docker/weewx/html/:/home/weewx/public_html/
    environment:
      - timezone=Europe/Brussels
      - WEEWX_UID=weewx
      - WEEWX_GID=dialout
-------------------
This docker requires in my data folder of course the configuration file. At first install, this file is created, then, you can fill it out. I copy here the most important parts of my weewx.conf.

##############################################################################

# This section is for general configuration information.

# Set to 1 for extra debug info, otherwise comment it out or set to zero
debug = 2

# Root directory of the weewx data file hierarchy for this station
WEEWX_ROOT = /home/weewx

# Whether to log successful operations. May get overridden below.
log_success = True

# Whether to log unsuccessful operations. May get overridden below.
log_failure = True

# Do not modify this. It is used when installing and updating weewx.
version = 4.10.2

##############################################################################
#   This section is for information about the station.

[Station]
   
    # Description of the station location
    location = "Thuis"
   
    # Latitude in decimal degrees. Negative for southern hemisphere
    latitude = fill_in_your_latitude
    # Longitude in decimal degrees. Negative for western hemisphere.
    longitude = fill_in_your_longitude
   
    # Altitude of the station, with the unit it is in. This is used only
    # if the hardware cannot supply a value.
    altitude = 41, meter    # Choose 'foot' or 'meter' for unit
   
    # Set to type of station hardware. There must be a corresponding stanza
    # in this file, which includes a value for the 'driver' option.
    station_type = Interceptor
  


    # If you have a website, you may specify an URL. This is required if you
    # intend to register your station.
    #station_url = http://www.example.com
   
    # The start of the rain year (1=January; 10=October, etc.). This is
    # downloaded from the station if the hardware supports it.
    rain_year_start = 1
   
    # Start of week (0=Monday, 6=Sunday)
    week_start = 0

##############################################################################

[Interceptor]
    # This section is for the network traffic interceptor driver.

    # The driver to use:
    driver = user.interceptor
    device_type = wu-client   #### this is used for all undefined clients which just upload to Wunderground.
    mode = listen
    address = my_weewx_server_ip_address
    port = 3010
##################################################
#   This section is for uploading data to Internet sites

[StdRESTful]
   
    # Uncomment and change to override logging for uploading services.
    # log_success = True
    # log_failure = True
    [[Wunderground]]
        # This section is for configuring posts to the Weather Underground.
       
        # If you wish to post to the Weather Underground, set the option 'enable' to true,  then
        # specify a station (e.g., 'KORHOODR3') and password. To guard against parsing errors, put
        # the password in quotes.
        enable = true
        station = 'station_name'
        password = 'myKEY'
        
        # Set the following to True to have weewx use the WU "Rapidfire"
        # protocol. Not all hardware can support it. See the User's Guide.
        rapidfire = true

    [[MQTT]]
        server_url = mqtt://my_mqtt_server_IP:1883/
        topic = weather
		      unit_system = METRIC
		      binding = loop
		        [[[inputs]]]
            [[[[rain]]]]
                name = dayRain_mm
				            units = mm      
            [[[[rainRate]]]]
                name = rainRate_mm_per_hour
                units = mm_per_hour

```

# weewx-wdc-interceptor-docker - ORIGINAL TEXT, not being used for me.

A simple Dockerfile to run [weewx](https://github.com/weewx/weewx) with the [interceptor](https://github.com/matthewwall/weewx-interceptor) driver.
The [weewx-forecast](https://github.com/chaunceygardiner/weewx-forecast/) extension is also installed along with
[weewx-wdc](https://github.com/Daveiano/weewx-wdc), [weewx-xcumulative](https://github.com/gjr80/weewx-xcumulative), [weewx-xaggs](https://github.com/tkeffer/weewx-xaggs),
[weewx-GTS](https://github.com/roe-dl/weewx-GTS), and [weewx-cmon](https://github.com/bellrichm/weewx-cmon).

There are branches available with [weewx-DWD](https://github.com/roe-dl/weewx-DWD), [weewx-mqtt](https://github.com/matthewwall/weewx-mqtt) and both extensions together.

WeeWX is installed via the [`pip` installation method](https://www.weewx.com/docs/5.0/quickstarts/pip/).

Go to the original files: [weewx-Daveiano](https://github.com/Daveiano/weewx-wdc-interceptor-docker/)
