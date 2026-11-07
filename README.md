# PetNickname

Give your pet a nickname that only you can see. Made for warlocks who want to call their Voidwalker something better than the name the game rolled for it, but it works for any pet.

Built for WoW Forever (interface 16001).

## Usage

Summon your pet, then:

| Command | What it does |
|---|---|
| `/petname <name>` | Give your current pet a nickname |
| `/petname reset` | Remove the nickname of your current pet |
| `/petname list` | List all nicknames on this character |
| `/petname` | Show the current pet's nickname |

Nicknames are saved per character and keyed by the pet's real name, so your Imp, Voidwalker and Succubus each keep their own.

## Where the nickname shows

- EllesmereUI unit frames: Pet, Target, Target of Target, Focus and Focus Target
- The pet's nameplate, if you show nameplates for your pet
- The unit tooltip

## Limits

- The floating name above the pet in the game world is drawn by the game engine. No addon can change it.
- Combat log and chat messages keep the real name.
- The nickname is client side only. Other players still see the real name.

## License

MIT, see [LICENSE](LICENSE).
