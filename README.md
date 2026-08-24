# FS25_InvoicesProductionSales

Farm-to-farm production sales for Farming Simulator 25, integrated with FS25_Invoices.

[![Version](https://img.shields.io/badge/version-1.0.0.0-blue.svg)](https://github.com/Squallqt/FS25_InvoicesProductionSales/releases)
[![FS25](https://img.shields.io/badge/FS25-compatible-green.svg)](https://farming-simulator.com/)
[![Multiplayer](https://img.shields.io/badge/multiplayer-supported-success.svg)](#)
[![Languages](https://img.shields.io/badge/languages-27-blue.svg)](#)
[![License](https://img.shields.io/badge/license-proprietary-red.svg)](LICENSE)

Publish stored production outputs at your own tax-inclusive price and sell them directly to other farms. Buyers can collect bulk goods from the production or purchase full pallets, while every transaction is paid immediately and recorded in a paid summary invoice.

The mod adds a dedicated **Production Sales** section to FS25_Invoices with a marketplace, seller offer management, and a clear overview of paid sales waiting to be invoiced.

> **Required dependency:** FS25_Invoices version 1.2.0.0 or later.

## Features

* **Production marketplace**: browse active offers published by other farms, with seller, production, product, available stock, sale mode, pallet count, and tax-inclusive price per 1,000 liters
* **Seller-controlled offers**: farm managers list a volume for bulk or mixed outputs, or a number of full pallets for pallet-only outputs, then set their own tax-inclusive price before opening the offer
* **Flexible pricing**: the suggested price follows the current in-game market value, and the price of an active offer can be changed without altering its listed quantity
* **Bulk collection**: buyers load offered products directly at the production loading point and confirm the purchase before filling
* **Full-pallet purchases**: buyers choose how many full pallets to buy, ownership transfers immediately, and the pallets stay at the production until collected
* **Immediate payment**: buyers are charged only for the volume actually transferred, with the server validating buyer, offer, price, stock, and funds
* **Insufficient-funds protection**: bulk loading is capped at the affordable volume and stops safely when the buyer can no longer pay
* **Paid summary invoices**: completed purchases are grouped by seller and buyer for the current month, then added to FS25_Invoices as already paid invoices without a second payment
* **Automatic or manual invoicing**: summary invoices are issued when the in-game month changes, or early by the seller from **My Sales**
* **Full multiplayer sync**: server-authoritative offers, purchases, money transfers and pallet ownership, with late-join support and savegame persistence
* **Farm Manager permission** required for seller operations, while any farm member can purchase active offers
* **27 languages** supported, the same set as FS25_Invoices

## Installation

### From ModHub

Download from the official [Farming Simulator ModHub](https://www.farming-simulator.com/mods.php).

### Manual Installation

1. Place the downloaded `FS25_InvoicesProductionSales.zip` file into your Farming Simulator 25 `mods/` directory (do not extract)
2. Install FS25_Invoices version 1.2.0.0 or later in the same directory
3. Activate both mods in the mod selection screen

## Usage

Open **Invoices** from the in-game menu, then select **Production Sales**.

### Market

The **Market** displays active offers from other farms.

* For bulk goods, drive a compatible vehicle to the production loading point, start filling, and confirm the displayed purchase details
* For pallets, select an offer, choose **Buy Pallets**, enter the required quantity, and confirm the purchase
* The lower section shows the current farm's purchases already paid during the current month

### My Offers

The **My Offers** page lists the current farm's production outputs.

1. Select an output using the native **Store** distribution mode
2. Choose **Open Offer**
3. Enter the volume in liters for a bulk or mixed output, or the number of full pallets for a pallet-only output, then enter the tax-inclusive price per 1,000 liters
4. Once the offer is active, its price can be updated or the offer can be closed

The listed quantity cannot be reduced while the offer remains active. Outputs configured as **Sell** or **Distribute** cannot be published: change the production output to **Store** before opening the offer.

### My Sales

The **My Sales** page groups paid purchases by buyer for the current month. Select a buyer and choose **Issue Invoice** to create the paid summary invoice immediately. Otherwise, it is issued automatically when the in-game month changes.

The payment has already been transferred during each purchase. Issuing the summary invoice records the completed sales in FS25_Invoices and does not charge the buyer again.

## Compatibility

* FS25_Invoices version 1.2.0.0 or later
* Production outputs stored as bulk goods or full pallets

Inputs, bales, big bags, independent silos, and direct production selling are not managed by this mod.

## Storage

Production sales data is saved with the current savegame in:

`invoicesProductionSales.xml`

## Changelog

### v1.0.0.0

* Initial release

## Support

* [GitHub Issues](https://github.com/Squallqt/FS25_InvoicesProductionSales/issues)
* [GitHub Discussions](https://github.com/Squallqt/FS25_InvoicesProductionSales/discussions)

## License

Copyright © 2026 Squallqt. All rights reserved.

This project is proprietary software and is not distributed under an
open-source license.

Downloading an official release for private use with Farming Simulator 25 is
permitted. Copying, modifying, converting, redistributing, reuploading,
commercializing, or reusing any part of this project requires prior written
authorization.

See the [LICENSE](LICENSE) file for the complete terms.
