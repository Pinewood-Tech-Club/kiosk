# Ice Cream Kiosk

Custom kiosk app for selling ice cream used at Jamboree, Pinewood's annual fundraiser for clubs. Was pretty popular!

And yes, it does in fact accept real money through the Square Mobile Payments SDK :)

<img width="2714" height="1210" alt="Cleanshot 2026-11-26 at 01 01 39@2x" src="https://github.com/user-attachments/assets/97abaa29-7773-48a7-a605-b299392dc2f3" />

## Features

* It has cool 3D graphics
* Connects to the Square API **and** uses the Square Mobile Payments SDK to both connect to the physical square reader and also get information from the square backend! Yes, it accepts real payments
* Very simplistic order management screen to actually see the orders that people submit from the kiosk
* Minimal inventory management (for marking items as out of stock)

## Setting up

Under `Config/Local.xcconfig.example` you'll have to rename that to remove the .example at the end and then actually fill in the things, which should be explained by the comments there. You will need to make a Square developer account first at [here](https://developer.squareup.com/us/en), but luckily, unlike the Apple one, it's FREE! You will also either need the ID for a real square "location" (which is what they call a store/whatever) or one in their sandbox, which is also free for testing!

## Running it

First you have to actually set it up (see above), but other than that running it is similar to basically any other iOS app!

Open up `Kiosk.xcodeproj` in Xcode and click the play button. You will need a paid apple developer account to accept real payments as the Square Mobile Payments SDK requires it!

## Disclaimers

This is not very good for production use as you are hardcoding tokens and stuff locally. It was fine for my use case because I was the one installing the thing onto my own iPad so no biggie there but obviously you wouldn't want to hardcode tokens into a real iOS app!
