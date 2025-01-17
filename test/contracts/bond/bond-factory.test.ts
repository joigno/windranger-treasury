// Start - Support direct Mocha run & debug
import 'hardhat'
import '@nomiclabs/hardhat-ethers'
// End - Support direct Mocha run & debug

import chai, {expect} from 'chai'
import {before} from 'mocha'
import {solidity} from 'ethereum-waffle'
import {
    BitDAO,
    BondFactory,
    IERC20,
    SingleCollateralMultiRewardBond
} from '../../../typechain-types'
import {
    contractAt,
    deployContract,
    execute,
    signer
} from '../../framework/contracts'
import {SignerWithAddress} from '@nomiclabs/hardhat-ethers/signers'
import {successfulTransaction} from '../../framework/transaction'
import {
    ExpectedBeneficiaryUpdateEvent,
    verifyBeneficiaryUpdateEvents,
    verifyBeneficiaryUpdateLogEvents
} from '../../event/sweep/verify-token-sweep-events'
import {
    ExpectedERC20SweepEvent,
    verifyERC20SweepEvents,
    verifyERC20SweepLogEvents
} from '../../event/sweep/verify-sweep-erc20-events'
import {events} from '../../framework/events'
import {Bond} from '../../../typechain-types/contracts/bond/BondFactory'
import {
    ExpectCreateBondEvent,
    verifyCreateBondEventLogs,
    verifyCreateBondEvents
} from '../../event/bond/verify-bond-creator-events'
import {createBondEvents} from '../../event/bond/bond-creator-events'

// Wires up Waffle with Chai
chai.use(solidity)

describe('Bond Factory contract', () => {
    before(async () => {
        admin = (await signer(0)).address
        treasury = (await signer(1)).address
        nonAdmin = await signer(2)
        collateralTokens = await deployContract<BitDAO>('BitDAO', admin)
        creator = await deployContract<BondFactory>('BondFactory', treasury)
    })

    describe('create bond', () => {
        after(async () => {
            if (await creator.paused()) {
                await creator.unpause()
            }
        })

        it('with BIT token collateral', async () => {
            const bondName = 'Special Debt Certificate'
            const bondSymbol = 'SDC001'
            const debtTokenAmount = 555666777n
            const expiryTimestamp = 560000n
            const minimumDeposit = 100n
            const data = 'a random;delimiter;separated string'

            const receipt = await execute(
                creator.createBond(
                    {name: bondName, symbol: bondSymbol, data: data},
                    {
                        debtTokenAmount: debtTokenAmount,
                        collateralTokens: collateralTokens.address,
                        expiryTimestamp: expiryTimestamp,
                        minimumDeposit: minimumDeposit
                    },
                    [],
                    treasury
                )
            )
            const expectedCreateBondEvent: ExpectCreateBondEvent[] = [
                {
                    metadata: {name: bondName, symbol: bondSymbol, data: data},
                    configuration: {
                        debtTokenAmount: debtTokenAmount,
                        collateralTokens: collateralTokens.address,
                        expiryTimestamp: expiryTimestamp,
                        minimumDeposit: minimumDeposit
                    },
                    rewards: [],
                    treasury: treasury,
                    instigator: admin
                }
            ]
            verifyCreateBondEvents(receipt, expectedCreateBondEvent)
            verifyCreateBondEventLogs(creator, receipt, expectedCreateBondEvent)
        })

        it('passed through multi rewards', async () => {
            const bondName = 'Special Debt Certificate'
            const bondSymbol = 'SDC001'
            const debtTokenAmount = 555666777n
            const expiryTimestamp = 560000n
            const minimumDeposit = 100n
            const data = 'a random;delimiter;separated string'
            const rewards = [
                {
                    tokens: collateralTokens.address,
                    amount: 4000n,
                    timeLock: 4n
                },
                {
                    tokens: nonAdmin.address,
                    amount: 27500n,
                    timeLock: 75n
                }
            ]

            const receipt = await execute(
                creator.createBond(
                    {name: bondName, symbol: bondSymbol, data: data},
                    {
                        debtTokenAmount: debtTokenAmount,
                        collateralTokens: collateralTokens.address,
                        expiryTimestamp: expiryTimestamp,
                        minimumDeposit: minimumDeposit
                    },
                    rewards,
                    treasury
                )
            )
            const expectedCreateBondEvent: ExpectCreateBondEvent[] = [
                {
                    metadata: {name: bondName, symbol: bondSymbol, data: data},
                    configuration: {
                        debtTokenAmount: debtTokenAmount,
                        collateralTokens: collateralTokens.address,
                        expiryTimestamp: expiryTimestamp,
                        minimumDeposit: minimumDeposit
                    },
                    rewards,
                    treasury: treasury,
                    instigator: admin
                }
            ]
            verifyCreateBondEvents(receipt, expectedCreateBondEvent)
            verifyCreateBondEventLogs(creator, receipt, expectedCreateBondEvent)

            // Does the Bond have the correct rewards?
            const bond: SingleCollateralMultiRewardBond = await contractAt(
                'SingleCollateralMultiRewardBond',
                createBondEvents(events('CreateBond', receipt))[0].bond
            )
            expectTimeLockRewardsEquals(
                rewards,
                await bond.timeLockRewardPools()
            )
        })

        it('only when not paused', async () => {
            await successfulTransaction(creator.pause())
            expect(await creator.paused()).is.true

            await expect(
                creator.createBond(
                    {name: 'Named bond', symbol: 'AA00AA', data: ''},
                    {
                        debtTokenAmount: 101n,
                        collateralTokens: collateralTokens.address,
                        expiryTimestamp: 0n,
                        minimumDeposit: 0n
                    },
                    [],
                    treasury
                )
            ).to.be.revertedWith('Pausable: paused')
        })
    })

    describe('ERC20 token sweep', () => {
        it('init', async () => {
            const bondFactory = await deployContract<BondFactory>(
                'BondFactory',
                treasury
            )

            expect(await bondFactory.tokenSweepBeneficiary()).equals(treasury)
        })

        describe('update beneficiary', () => {
            after(async () => {
                creator = await deployContract<BondFactory>(
                    'BondFactory',
                    treasury
                )
            })

            it('side effects', async () => {
                expect(await creator.tokenSweepBeneficiary()).equals(treasury)

                const receipt = await successfulTransaction(
                    creator.setTokenSweepBeneficiary(nonAdmin.address)
                )

                expect(await creator.tokenSweepBeneficiary()).equals(
                    nonAdmin.address
                )
                const expectedEvents: ExpectedBeneficiaryUpdateEvent[] = [
                    {
                        beneficiary: nonAdmin.address,
                        instigator: admin
                    }
                ]
                verifyBeneficiaryUpdateEvents(receipt, expectedEvents)
                verifyBeneficiaryUpdateLogEvents(
                    creator,
                    receipt,
                    expectedEvents
                )
            })

            it('only owner', async () => {
                await expect(
                    creator
                        .connect(nonAdmin)
                        .setTokenSweepBeneficiary(nonAdmin.address)
                ).to.be.revertedWith('Ownable: caller is not the owner')
            })
            it('only when not paused', async () => {
                await creator.pause()

                await expect(
                    creator.setTokenSweepBeneficiary(nonAdmin.address)
                ).to.be.revertedWith('Pausable: paused')
            })
        })

        describe('ERC20 token sweep', () => {
            after(async () => {
                creator = await deployContract<BondFactory>(
                    'BondFactory',
                    treasury
                )
            })
            it('side effects', async () => {
                const seedFunds = 100n
                const sweepAmount = 55n
                await successfulTransaction(
                    collateralTokens.transfer(creator.address, seedFunds)
                )
                expect(
                    await collateralTokens.balanceOf(creator.address)
                ).equals(seedFunds)
                expect(await collateralTokens.balanceOf(treasury)).equals(0)

                const receipt = await successfulTransaction(
                    creator.sweepERC20Tokens(
                        collateralTokens.address,
                        sweepAmount
                    )
                )

                expect(
                    await collateralTokens.balanceOf(creator.address)
                ).equals(seedFunds - sweepAmount)
                expect(await collateralTokens.balanceOf(treasury)).equals(
                    sweepAmount
                )
                const expectedEvents: ExpectedERC20SweepEvent[] = [
                    {
                        beneficiary: treasury,
                        tokens: collateralTokens.address,
                        amount: sweepAmount,
                        instigator: admin
                    }
                ]
                verifyERC20SweepEvents(receipt, expectedEvents)
                verifyERC20SweepLogEvents(creator, receipt, expectedEvents)
            })

            it('only owner', async () => {
                await expect(
                    creator
                        .connect(nonAdmin)
                        .sweepERC20Tokens(collateralTokens.address, 5)
                ).to.be.revertedWith('Ownable: caller is not the owner')
            })

            it('only when not paused', async () => {
                await creator.pause()

                await expect(
                    creator.sweepERC20Tokens(collateralTokens.address, 5)
                ).to.be.revertedWith('Pausable: paused')
            })
        })
    })

    describe('pause', () => {
        after(async () => {
            if (await creator.paused()) {
                await creator.unpause()
            }
        })

        it('only owner', async () => {
            await expect(creator.connect(nonAdmin).pause()).to.be.revertedWith(
                'Ownable: caller is not the owner'
            )
        })

        it('changes state', async () => {
            expect(await creator.paused()).is.false

            await creator.pause()

            expect(await creator.paused()).is.true
        })

        it('only when not paused', async () => {
            await expect(creator.pause()).to.be.revertedWith('Pausable: paused')
        })
    })

    describe('unpause', () => {
        before(async () => {
            if (!(await creator.paused())) {
                await creator.pause()
            }
        })
        after(async () => {
            if (await creator.paused()) {
                await creator.unpause()
            }
        })

        it('only owner', async () => {
            await expect(
                creator.connect(nonAdmin).unpause()
            ).to.be.revertedWith('Ownable: caller is not the owner')
        })

        it('changes state', async () => {
            expect(await creator.paused()).is.true

            await creator.unpause()

            expect(await creator.paused()).is.false
        })

        it('only when paused', async () => {
            await expect(creator.unpause()).to.be.revertedWith(
                'Pausable: not paused'
            )
        })
    })

    let admin: string
    let treasury: string
    let nonAdmin: SignerWithAddress
    let collateralTokens: IERC20
    let creator: BondFactory
})

function expectTimeLockRewardsEquals(
    expected: Bond.TimeLockRewardPoolStruct[],
    actual: Bond.TimeLockRewardPoolStructOutput[]
): void {
    expect(expected.length).equals(actual.length)

    for (let i = 0; i < expected.length; i++) {
        verifyTimeLockRewardPool(expected[i], actual[i])
    }
}

function verifyTimeLockRewardPool(
    expected: Bond.TimeLockRewardPoolStruct,
    actual: Bond.TimeLockRewardPoolStructOutput
): void {
    expect(expected.tokens).equals(actual.tokens)
    expect(expected.amount).equals(actual.amount)
    expect(expected.timeLock).equals(actual.timeLock)
}
