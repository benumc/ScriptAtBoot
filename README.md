# ScriptAtBoot
Helpful for making scripts run when Savant host boots

Both scripts are designed to run MyScript.rb (easily modified to script of choice) located in the RPM directory of a savant host.

##MyScriptSmartHost.sh

The MyScript.rb will need to be made executable with the command ```chmod +x /home/RPM/MyScript.rb```

The MyScriptSmartHost.sh boot script needs to be located in the directory ```/etc/init.d/``` and can be renamed.

If you change the name of MyScript.rb, you will need modify the MyScriptSmartHost.sh script to match.

Once everything is in place, you can test the service with the command ```sudo service MyScriptSmartHost.sh start```

Then use the command ```sudo service MyScriptSmartHost.sh status``` to make sure it is running properly.

Finally you need to attach the script to the boot sequence with the command ```sudo update-rc.d myservice.sh defaults```

##MyScriptProHost.plist

Generally speaking this script just needs to be dropped into the ```~/RPM/Library/LaunchAgents/``` directory of your ProHost.

Once again, if you rename MyScript.rb you will need to modify the plist to match.
