//SPDX-License-Identifier: MIT

// This is an Open Invariant Testing file because it runs test on different functions in the selected file to ascertain  an invariant holds
//In our file, some of our invariants (property of the system that should not change) would be
// 1 The total amount of DSC Minted should be less than our collateral value;
//  2 Our getter functions should never revert <--- Evergreen invariant
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "../../test/fuzz/Handler.t.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce,dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanSupply() public view {
        // We will get the value of collateral in the dscEngine
        //We will compare it with debt(dsc minted)

        uint256 totalSupply = dsc.totalSupply();

        uint256 wethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 wbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, wethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

        console.log("Weth value is:", wethValue);
        console.log("Wbtc value is:", wbtcValue);
        console.log("total supply value is:", totalSupply);

        assert(wethValue + wbtcValue >= totalSupply);
    }

    //  This is the part where we test our getter properties in our src file
    function invariant_gettersShouldNotRevert() public view {
        dsce.getLiquidationBonus();
        dsce.getAccountInformation(msg.sender);
        //   dsce.getUsdValue(weth, );
    }
}
