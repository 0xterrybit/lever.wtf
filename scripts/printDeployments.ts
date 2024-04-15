import hre from "hardhat";

async function main() {
  const { deployments } = hre;
  const allDeployments = await deployments.all();
  for (const [contractName, { address }] of Object.entries(allDeployments)) {
    if (process.env.TABLE_FORMAT) {
      console.log(`${process.env.EXPLORER_URL}/address/${address},${contractName}`);
    } else {
      console.log(contractName, address);
    }
  }
}

main()
  .then(() => {
    process.exit(0);
  })
  .catch((ex) => {
    console.error(ex);
    process.exit(1);
  });
