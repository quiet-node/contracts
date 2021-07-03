// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./PackControl.sol";
import "./PackERC1155.sol";
import "./RewardERC1155.sol";

contract Market is ReentrancyGuard {

  PackControl internal packControl;

  string public constant REWARD_ERC1155_MODULE_NAME = "REWARD_ERC1155";
  string public constant PACK_ERC1155_MODULE_NAME = "PACK_ERC1155";
  string public constant PACK_ASSET_MANAGER = "PACK_ASSET_MANAGER";

  enum ListingType { Pack, Reward }

  event NewListing(address indexed seller, uint indexed tokenId, address currency, uint price, uint quantity, ListingType listingType);
  event NewSale(address indexed seller, address indexed buyer, uint indexed tokenId, address currency, uint price, uint quantity);
  event ListingUpdate(address indexed seller, uint indexed tokenId, address currency, uint price, uint quantity);
  event Unlisted(address indexed seller, uint indexed tokenId, uint quantity);

  uint public constant MAX_BPS = 10000; // 100%
  uint public protocolFeeBps = 500; // 5%
  uint public creatorFeeBps = 500; // 5%

  struct Listing {
    address owner;
    uint tokenId;

    uint quantity;
    address currency;
    uint price;
    ListingType listingType;
  }

  /// @dev Owner => tokenId => Listing
  mapping(address => mapping(uint => Listing)) public listings;

  modifier onlySeller(uint tokenId) {
    require(listings[msg.sender][tokenId].owner != address(0), "Only the seller can modify the listing.");
    _;
  }

  constructor(address _packControl) {
    packControl = PackControl(_packControl);
  }

  /// @notice Lets `msg.sender` list a given amount of pack tokens for sale.
  function listPacks(
    uint _tokenId, 
    address _currency, 
    uint _price, 
    uint _quantity
  ) external {
    require(packERC1155().isApprovedForAll(msg.sender, address(this)), "Must approve the market to transfer pack tokens.");
    require(_quantity > 0, "Must list at least one token");

    // Transfer tokens being listed to Pack Protocol's asset manager.
    packERC1155().safeTransferFrom(
      msg.sender,
      assetManager(),
      _tokenId,
      _quantity,
      ""
    );

    // Store listing state.
    listings[msg.sender][_tokenId] = Listing({
      owner: msg.sender,
      tokenId: _tokenId,
      currency: _currency,
      price: _price,
      quantity: _quantity,
      listingType: ListingType.Pack
    });

    emit NewListing(msg.sender, _tokenId, _currency, _price, _quantity, ListingType.Pack);
  }

  /// @notice Lets `msg.sender` list a given amount of reward tokens for sale.
  function listRewards(
    uint _tokenId, 
    address _currency, 
    uint _price, 
    uint _quantity
  ) external {
    require(rewardERC1155().isApprovedForAll(msg.sender, address(this)), "Must approve the market to transfer reward tokens.");
    require(_quantity > 0, "Must list at least one token");

    // Transfer tokens being listed to this contract.
    rewardERC1155().safeTransferFrom(
      msg.sender,
      assetManager(),
      _tokenId,
      _quantity,
      ""
    );

    // Store listing state.
    listings[msg.sender][_tokenId] = Listing({
      owner: msg.sender,
      tokenId: _tokenId,
      currency: _currency,
      price: _price,
      quantity: _quantity,
      listingType: ListingType.Reward
    });

    emit NewListing(msg.sender, _tokenId, _currency, _price, _quantity, ListingType.Reward);
  }

  /// @notice Lets a seller unlist `quantity` amount of tokens.
  function unlist(uint _tokenId, uint _quantity) external onlySeller(_tokenId) {
    require(listings[msg.sender][_tokenId].quantity >= _quantity, "Cannot unlist more tokens than are listed.");

    // Transfer way tokens being unlisted.
    PackERC1155(
      packControl.getModule(PACK_ERC1155_MODULE_NAME)
    ).safeTransferFrom(
      assetManager(),
      msg.sender,
      _tokenId,
      _quantity,
      ""
    );

    emit Unlisted(msg.sender, _tokenId, _quantity);
  }

  /// @notice Lets a seller change the currency or price of a listing.
  function setPriceStatus(uint tokenId, address _newCurrency, uint _newPrice) external onlySeller(tokenId) {
    
    // Store listing state.
    listings[msg.sender][tokenId].price = _newPrice;
    listings[msg.sender][tokenId].currency = _newCurrency;

    emit ListingUpdate(
      msg.sender,
      tokenId,
      listings[msg.sender][tokenId].currency, 
      listings[msg.sender][tokenId].price, 
      listings[msg.sender][tokenId].quantity
    );
  }

  /// @notice Lets buyer buy a given amount of tokens listed for sale.
  function buy(address _from, uint _tokenId, uint _quantity) external payable nonReentrant {
    require(listings[_from][_tokenId].owner != address(0), "The listing does not exist.");
    require(_quantity <= listings[_from][_tokenId].quantity, "attempting to buy more tokens than listed");

    Listing memory listing = listings[_from][_tokenId];

    // Get token creator.
    address creator;

    if(listing.listingType == ListingType.Pack) {
      (creator,,) = packERC1155().tokens(_tokenId);
    } else if(listing.listingType == ListingType.Reward) {
      (creator,,,) = rewardERC1155().tokens(_tokenId);
    }
    
    // Distribute sale value to seller, creator and protocol.
    if(listing.currency == address(0)) {
      distributeEther(listing.owner, creator, listing.price, _quantity);
    } else {
      distributeERC20(listing.owner, creator, listing.currency, listing.price, _quantity);
    }

    // Transfer tokens to buyer.
    if(listing.listingType == ListingType.Pack) {
      packERC1155().safeTransferFrom(assetManager(), msg.sender, _tokenId, _quantity, "");
    } else if(listing.listingType == ListingType.Reward) {
      rewardERC1155().safeTransferFrom(assetManager(), msg.sender, _tokenId, _quantity, "");
    }
    
    // Update quantity of tokens in the listing.
    listings[_from][_tokenId].quantity -= _quantity;

    emit NewSale(_from, msg.sender, _tokenId, listing.currency, listing.price, _quantity);
  }

  /// @notice Distributes relevant shares of the sale value (in ERC20 token) to the seller, creator and protocol.
  function distributeERC20(address seller, address creator, address currency, uint price, uint quantity) internal {
    
    // Get value distribution parameters.
    uint totalPrice = price * quantity;
    uint protocolCut = (totalPrice * protocolFeeBps) / MAX_BPS;
    uint creatorCut = seller == creator ? 0 : (totalPrice * creatorFeeBps) / MAX_BPS;
    uint sellerCut = totalPrice - protocolCut - creatorCut;
    
    require(
      IERC20(currency).allowance(msg.sender, address(this)) >= totalPrice, 
      "Not approved PackMarket to handle price amount."
    );

    // Distribute relveant shares of sale value to seller, creator and protocol.
    require(IERC20(currency).transferFrom(msg.sender, packControl.treasury(), protocolCut), "Failed to transfer protocol cut.");
    require(IERC20(currency).transferFrom(msg.sender, seller, sellerCut), "Failed to transfer seller cut.");

    if (creatorCut > 0) {
      require(IERC20(currency).transferFrom(msg.sender, creator, creatorCut), "Failed to transfer creator cut.");
    }
  }

  /// @notice Distributes relevant shares of the sale value (in Ether) to the seller, creator and protocol.
  function distributeEther(address seller, address creator, uint price, uint quantity) internal {
    
    // Get value distribution parameters.
    uint totalPrice = price * quantity;
    uint protocolCut = (totalPrice * protocolFeeBps) / MAX_BPS;
    uint creatorCut = seller == creator ? 0 : (totalPrice * creatorFeeBps) / MAX_BPS;
    uint sellerCut = totalPrice - protocolCut - creatorCut;

    require(msg.value >= totalPrice, "Must sent enough eth to buy the given amount.");

    // Distribute relveant shares of sale value to seller, creator and protocol.
    (bool success,) = packControl.treasury().call{value: protocolCut}("");
    require(success, "Failed to transfer protocol cut.");

    (success,) = seller.call{value: sellerCut}("");
    require(success, "Failed to transfer seller cut.");

    if (creatorCut > 0) {
        (success,) = creator.call{value: creatorCut}("");
      require(success, "Failed to transfer creator cut.");
    }
  }

  /// @dev Returns pack protocol's reward ERC1155 contract.
  function packERC1155() internal view returns (PackERC1155) {
    return PackERC1155(packControl.getModule(PACK_ERC1155_MODULE_NAME));
  }

  /// @dev Returns pack protocol's reward ERC1155 contract.
  function rewardERC1155() internal view returns (RewardERC1155) {
    return RewardERC1155(packControl.getModule(REWARD_ERC1155_MODULE_NAME));
  }

  /// @dev Returns pack protocol's asset manager address.
  function assetManager() internal view returns (address) {
    return packControl.getModule(PACK_ASSET_MANAGER);
  }
}