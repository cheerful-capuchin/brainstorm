## Context
I've created a catalog of the markets in market-info/assets.
However, we still have a hardcoded list of assets in market-info/src/asset/asset_list.rs

I think I need to create something like "AssetInfo" trait and store the assets in market-info/assets/assets.
Additionally, there should be a market-info/assets/assets.csv with the list of all the assets and their respective IDs.

Then, we'll have the Asset Repo that loads some kind of binary file with assets.

Propose the solution for the asset catalog, assets.csv and the compiled list in the rkyv file



