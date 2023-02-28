const { expect, assert } = require("chai");
const { ethers, upgrades, waffle } = require("hardhat");


describe("nft", function () {

    before(async function () {

        this.signers = await ethers.getSigners()
        this.owner = this.signers[0]
        this.user = this.signers[1]

        // mock nft
        this.NFTMock = await ethers.getContractFactory("NFTMock");
        this.nft = await this.NFTMock.deploy("TEST-NFT", "TEST-NFT")

        //mock pricehelper
        this.PriceHelperMock = await ethers.getContractFactory("PriceHelperMock");
        this.priceHelper = await this.PriceHelperMock.deploy()

        //deploy clink
        this.Clink = await ethers.getContractFactory("Clink");
        this.clink = await this.Clink.deploy(this.owner.address)
        await this.clink.deployed();

        //deploy factory
        this.Factory = await ethers.getContractFactory("Factory");
        this.factory = await this.Factory.deploy()
        await this.factory.deployed();
        console.info(" factory ", this.factory.address)

        this.NFTVault = await ethers.getContractFactory("NFTVault")
        this.masterContract = await this.NFTVault.deploy(this.clink.address, this.owner.address)
        await this.masterContract.deployed();
        console.info(" masterContract ", this.masterContract.address)

        this.NFTSwapperMock = await ethers.getContractFactory("NFTSwapperMock")
        this.nFTSwapperMock = await this.NFTSwapperMock.deploy(this.clink.address)
        await this.nFTSwapperMock.deployed();
        console.info(" nFTSwapperMock ", this.nFTSwapperMock.address)

        this.debtInterestApr = [2, 10000]
        this.creditLimitRate = [85, 100]
        this.liquidationLimitRate = [95, 100]
        this.organizationFeeRate = [3, 1000]
        this.liquidationFeeRate = [2, 100]
        const initData = ethers.utils.defaultAbiCoder.encode(
            ["uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256", "address", "address"],
            [
                ...this.debtInterestApr,
                ...this.creditLimitRate,
                ...this.liquidationLimitRate,
                ...this.organizationFeeRate,
                ...this.liquidationFeeRate,
                this.nft.address,
                this.priceHelper.address
            ]
        );
        // deploy an nft vault instan
        const tx = await (
            await this.factory.deploy(this.masterContract.address, initData, true)
        ).wait();

        // get core address from tx event
        const deployEvent = tx?.events?.[0];
        const coreAddress = deployEvent?.args?.cloneAddress;
        this.nFTVault = this.NFTVault.attach(coreAddress);
        console.info(" nFTVault ", this.nFTVault.address)

        // grant the nft valut mint permissions
        await this.clink.connect(this.owner).addWL(this.nFTVault.address)
    })

    it("brrow", async function () {
        // mint a nft
        await this.nft.mint(this.user.address)
        this.tokenId = await this.nft.tokenOfOwnerByIndex(this.user.address, 0)
        // set the nft mock price, the value is $10000(10000000000000000000000)
        this.nftValue = ethers.BigNumber.from("10000000000000000000000")
        await this.priceHelper.setPrice(this.nft.address, this.tokenId, this.nftValue);
        this.maxBorrow = this.nftValue.mul(this.creditLimitRate[0]).div(this.creditLimitRate[1])

        // approve
        await this.nft.connect(this.user).setApprovalForAll(this.nFTVault.address, true)
        // set next block.timestamp = current time
        this.nextTimestamp = Math.floor(new Date() / 1000) + 60
        await network.provider.send("evm_setNextBlockTimestamp", [this.nextTimestamp])
        // the max amount can be borrowed is $10000*85%= $8500
        await this.nFTVault.connect(this.user).borrow(this.tokenId, this.maxBorrow)
        this.clkBalAfterBorrow = await this.clink.balanceOf(this.user.address)
        // the organizationFee is 3/1000, so the balance of the user is  $8500*(1-3/1000)= $8474.5(847450000000000000000)
        const clkBal1 = this.maxBorrow.mul(this.organizationFeeRate[1] - this.organizationFeeRate[0]).div(this.organizationFeeRate[1])
        assert.equal(this.clkBalAfterBorrow.toString(), clkBal1.toString())
    });

    it("repay", async function () {

        // mint 10000 clk for user 
        await this.clink.connect(this.owner).mint(this.user.address, "1000000000000000000000")
        this.clkBalAfterMint = await this.clink.balanceOf(this.user.address)
        const clkBal2 = this.clkBalAfterBorrow.add("1000000000000000000000");
        assert.equal(this.clkBalAfterMint.toString(), clkBal2.toString())
        await this.clink.connect(this.user).approve(this.nFTVault.address, "0xfffffffffffffffffffffffffff")

        const bal = await this.clink.balanceOf(this.user.address)
        // set next block.timestamp =this.nextTimestamp + 365*86400 ,past 365 days
        this.nextTimestamp = this.nextTimestamp + 365 * 86400
        await network.provider.send("evm_setNextBlockTimestamp", [this.nextTimestamp])
        await this.nFTVault.connect(this.user).repay(this.tokenId, bal)
        await this.nFTVault.connect(this.user).closePosition(this.tokenId)
        const nftOwner = await this.nft.ownerOf(this.tokenId)
        // check repay success
        assert.equal(this.user.address, nftOwner)

        //check debt amount
        const totalDebtAmount = await this.nFTVault.totalDebtAmount()
        assert.equal("0", totalDebtAmount.toString())

    });

    it("accrue, interest and organizationFee", async function () {

        // the interest  = debtAmount* interestRate = $8500 * 2/10000 = $1.7
        const debtInterest = this.maxBorrow.mul(this.debtInterestApr[0]).div(this.debtInterestApr[1])
        // organizationFee = this.maxBorrow * organizationFeeRate
        const organizationFee = this.maxBorrow.mul(this.organizationFeeRate[0]).div(this.organizationFeeRate[1])

        const totalFeeCollected = await this.nFTVault.totalFeeCollected()
        //check interest and organizationFee
        assert.equal(totalFeeCollected.toString(), debtInterest.add(organizationFee).toString())

        this.clkBalAfterRepay = this.clkBalAfterMint.sub(debtInterest).sub(this.maxBorrow)
        const clkBal2 = await this.clink.balanceOf(this.user.address)
        assert.equal(clkBal2.toString(), this.clkBalAfterRepay.toString())

    });

    it("collect ", async function () {

        const totalFeeCollected = await this.nFTVault.totalFeeCollected()
        const feeAddr = this.signers[1].address
        const bal1 = await this.clink.balanceOf(feeAddr)
        await this.masterContract.connect(this.owner).setFeeTo(feeAddr)
        await await this.nFTVault.collect();
        const bal2 = await this.clink.balanceOf(feeAddr)
        assert.equal(bal2.sub(bal1).toString(), totalFeeCollected.toString())

        // totalFeeCollected shoule be 0
        const totalFeeCollected1 = await this.nFTVault.totalFeeCollected()
        assert.equal("0", totalFeeCollected1.toString())
    });

    it("liquidate", async function () {

        // borrow
        await this.nFTVault.connect(this.user).borrow(this.tokenId, this.maxBorrow)

        const debtAmount = await this.nFTVault.getDebtAmount(this.tokenId)

        //the liquidate condition is userdebt >= nftValue * liquidate rate, so the nft Value threshold = userdebt/(liquidate rate)
        const liquidatePrice = debtAmount.div(this.liquidationLimitRate[0]).mul(this.liquidationLimitRate[1])
        await this.priceHelper.setPrice(this.nft.address, this.tokenId, liquidatePrice);

        // mint clk for the nFTSwapperMock
        await this.clink.connect(this.owner).mint(this.nFTSwapperMock.address, "1000000000000000000000000")

        await this.nFTVault.liquidate(this.tokenId, this.nFTSwapperMock.address, this.user.address)
        const nftOwner = await this.nft.ownerOf(this.tokenId)
        assert.equal(this.nFTSwapperMock.address, nftOwner)
    });


});
