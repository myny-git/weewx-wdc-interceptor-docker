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

Then, for the interceptor driver in weewx.conf:

```
[Interceptor]
    # This section is for the network traffic interceptor driver.

    # The driver to use:
    driver = user.interceptor
    device_type = wu-client   #### this is used for all undefined clients which just upload to Wunderground.
    mode = listen
    address = 0.0.0.0
    port = 3010

[StdRESTful]
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

# weewx-wdc-interceptor-docker - ORIGINAL AUTHOR.

A simple Dockerfile to run [weewx](https://github.com/weewx/weewx) with the [interceptor](https://github.com/matthewwall/weewx-interceptor) driver.
The [weewx-forecast](https://github.com/chaunceygardiner/weewx-forecast/) extension is also installed along with
[weewx-wdc](https://github.com/Daveiano/weewx-wdc), [weewx-xcumulative](https://github.com/gjr80/weewx-xcumulative), [weewx-xaggs](https://github.com/tkeffer/weewx-xaggs),
[weewx-GTS](https://github.com/roe-dl/weewx-GTS), and [weewx-cmon](https://github.com/bellrichm/weewx-cmon).

There are branches available with [weewx-DWD](https://github.com/roe-dl/weewx-DWD), [weewx-mqtt](https://github.com/matthewwall/weewx-mqtt) and both extensions together.

WeeWX is installed via the [`pip` installation method](https://www.weewx.com/docs/5.0/quickstarts/pip/).

Go to the original files: [weewx-Daveiano](https://github.com/Daveiano/weewx-wdc-interceptor-docker/)
