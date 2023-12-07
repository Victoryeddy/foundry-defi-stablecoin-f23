// //SPDX-License-Identifier: MIT

// // This is an Open Invariant Testing file because it runs test on different functions in the selected file to ascertain  an invariant holds
// //In our file, some of our invariants (property of the system that should not change) would be
// // 1 The total amount of DSC Minted should be less than our collateral value;
// //  2 Our getter functions should never revert <--- Evergreen invariant
// pragma solidity ^0.8.18;

// import {Test, console} from "forge-std/Test.sol";
// import {StdInvariant} from "forge-std/StdInvariant.sol";
// import {DeployDSC} from "../../script/DeployDSC.s.sol";
// import {DSCEngine} from "../../src/DSCEngine.sol";
// import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
// import {HelperConfig} from "../../script/HelperConfig.s.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// contract OpenInvariantTest is StdInvariant,Test {

//      DeployDSC deployer;
//      DSCEngine dsce;
//      DecentralizedStableCoin dsc;
//      HelperConfig config;
//      address weth;
//      address wbtc;
//     function setUp() public {
//          deployer = new DeployDSC();
//         (dsc,dsce,config) = deployer.run();
//         (,,weth,wbtc,) = config.activeNetworkConfig();
//         targetContract(address(dsce));
//     }

//     function invariant_protocolMustHaveMoreValueThanSupply() public view {
//        // We will get the value of collateral in the dscEngine
//        //We will compare it with debt(dsc minted)

//        uint256 totalSupply = dsc.totalSupply();

//        uint256 wethDeposited = IERC20(weth).balanceOf(address(dsce));
//        uint256 wbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

//       uint256 wethValue = dsce.getUsdValue(weth , wethDeposited);
//       uint256 wbtcValue = dsce.getUsdValue(wbtc , wbtcDeposited);

//       console.log(wethValue);
//       console.log(wbtcValue);
//       console.log(totalSupply);

//       assert(wethValue + wbtcValue >= totalSupply);
//     }
// }
