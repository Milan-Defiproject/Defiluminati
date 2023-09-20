// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../interfaces/IZenonLpConduit.sol";
import "../libraries/PoolSpecs.sol";

contract MockLpConduit is IZenonLpConduit {

    bool accept_;

    address public senderSnap_;
    bytes32 public poolSnap_;
    int24 public lowerSnap_;
    int24 public upperSnap_;
    uint128 public liqSnap_;
    uint64 public mileageSnap_;
    bool public isDeposit_;
    
    constructor (bool accept) {
        accept_ = accept;
    }

    function setAccept (bool accept) public {
        accept_ = accept;
    }

    function hashMatches (address base, address quote, uint256 poolIdx)
        public view returns (bool){
        return poolSnap_ == PoolSpecs.encodeKey(base, quote, poolIdx);
    }

    function depositCZenonLiq (address sender, bytes32 poolHash,
                             int24 lowerTick, int24 upperTick, uint128 liq,
                             uint64 mileage) public override returns (bool) {
        isDeposit_ = true;
        senderSnap_ = sender;
        poolSnap_ = poolHash;
        lowerSnap_ = lowerTick;
        upperSnap_ = upperTick;
        liqSnap_ = liq;
        mileageSnap_ = mileage;
        return accept_;
    }

    function withdrawZenonLiq (address sender, bytes32 poolHash,
                              int24 lowerTick, int24 upperTick, uint128 liq,
                              uint64 mileage) public override returns (bool) {
        isDeposit_ = false;
        senderSnap_ = sender;
        poolSnap_ = poolHash;
        lowerSnap_ = lowerTick;
        upperSnap_ = upperTick;
        liqSnap_ = liq;
        mileageSnap_ = mileage;
        return accept_;
    }

}
