# gcal

Looking for a calendar app on Arch, i came across this link: https://dsl.org/cookbook/cookbook_34.html and went through the rabbit hole!

I'm deeply touched by this extreme simplicity. All you need is a text file and you can get all your incoming events in the terminal. 
Quite naively and with the help of AI, I'm building a bash script (as a quick proof of concept) to integrate this radical simplicity with some contemporary .ics files.
Maybe you get some inspiration from this as well.

As i discovered the beauty of the bsdmainutils' calendar i also discovered how limited it is with today's use. This simple `gcal.sh` utility is made to download 
multiple .ics (iCal) feed; it then removes the past dates, make sure we have the correct date format+tab and turn them into a text file: calendar; which is in turn 
used by the `calendar` command to output either today-tomorrow list, or more.

## Requirements
- `calendar` is part of bsdmainutils; it's available on AUR
- chmod +x gcal.sh
- .env file will provide with an 'array' of urls to download events, one ics per line
