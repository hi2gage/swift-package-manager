//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _Concurrency
import Basics
import PackageGraph
import PackageLoading
import PackageModel
import PackageRegistry
import SourceControl
import Workspace
import XCTest

import struct TSCUtility.Version
import enum TSCBasic.JSON

extension UserToolchain {
    package static var mockTargetInfo: JSON {
        JSON.dictionary([
            "compilerVersion": .string("Apple Swift version 6.2-dev (LLVM 815013bbc318474, Swift 1459ecafa998782)")
        ])
    }

    package static func mockHostToolchain(
        _ fileSystem: InMemoryFileSystem,
        hostTriple: Triple = hostTriple
    ) throws -> UserToolchain {
        var hostSwiftSDK = try SwiftSDK.hostSwiftSDK(environment: .mockEnvironment, fileSystem: fileSystem)
        hostSwiftSDK.targetTriple = hostTriple

        let env = Environment.mockEnvironment

        return try UserToolchain(
            swiftSDK: hostSwiftSDK,
            environment: env,
            searchStrategy: .custom(
                searchPaths: getEnvSearchPaths(
                    pathString: env[.path],
                    currentWorkingDirectory: fileSystem.currentWorkingDirectory
                ),
                useXcrun: true
            ),
            customTargetInfo: Self.mockTargetInfo,
            fileSystem: fileSystem
        )
    }
}

extension Environment {
    package static var mockEnvironment: Self { ["PATH": "/fake/path/to"] }
}

extension InMemoryFileSystem {
    package func createMockToolchain() throws {
        let files = [
            "/fake/path/to/swiftc",
            "/fake/path/to/swiftc.exe",
            "/fake/path/to/ar",
            "/fake/path/to/ar.exe",
            "/fake/path/to/libtool",
            "/fake/path/to/libtool.exe",
            "/fake/path/to/link.exe",
            "/fake/path/to/lld-link.exe",
        ]
        self.createEmptyFiles(at: AbsolutePath.root, files: files)
        for toolPath in files {
            try self.updatePermissions(.init(toolPath), isExecutable: true)
        }
    }
}

public final class MockWorkspace {
    let sandbox: AbsolutePath
    let fileSystem: InMemoryFileSystem
    let roots: [MockPackage]
    let packages: [MockPackage]
    let customToolsVersion: ToolsVersion?
    private let customHostToolchain: UserToolchain
    let fingerprints: MockPackageFingerprintStorage
    let signingEntities: MockPackageSigningEntityStorage
    let mirrors: DependencyMirrors
    public var registryClient: RegistryClient
    let registry: MockRegistry
    let customBinaryArtifactsManager: Workspace.CustomBinaryArtifactsManager
    let customPrebuiltsManager: Workspace.CustomPrebuiltsManager?
    public var checksumAlgorithm: MockHashAlgorithm
    public private(set) var manifestLoader: MockManifestLoader
    public let repositoryProvider: InMemoryGitRepositoryProvider
    let identityResolver: IdentityResolver
    let customPackageContainerProvider: MockPackageContainerProvider?
    public let delegate = MockWorkspaceDelegate()
    let skipDependenciesUpdates: Bool
    public var sourceControlToRegistryDependencyTransformation: WorkspaceConfiguration
        .SourceControlToRegistryDependencyTransformation
    var defaultRegistry: Registry?
    public let traitConfiguration: TraitConfiguration
    public var enabledTraitsMap: EnabledTraitsMap
    public let pruneDependencies: Bool

    public init(
        sandbox: AbsolutePath,
        fileSystem: InMemoryFileSystem,
        roots: [MockPackage],
        packages: [MockPackage] = [],
        toolsVersion customToolsVersion: ToolsVersion? = .none,
        fingerprints customFingerprints: MockPackageFingerprintStorage? = .none,
        signingEntities customSigningEntities: MockPackageSigningEntityStorage? = .none,
        mirrors customMirrors: DependencyMirrors? = nil,
        registryClient customRegistryClient: RegistryClient? = .none,
        binaryArtifactsManager customBinaryArtifactsManager: Workspace.CustomBinaryArtifactsManager? = .none,
        prebuiltsManager customPrebuiltsManager: Workspace.CustomPrebuiltsManager? = .none,
        checksumAlgorithm customChecksumAlgorithm: MockHashAlgorithm? = .none,
        customPackageContainerProvider: MockPackageContainerProvider? = .none,
        skipDependenciesUpdates: Bool = false,
        sourceControlToRegistryDependencyTransformation: WorkspaceConfiguration
            .SourceControlToRegistryDependencyTransformation = .disabled,
        defaultRegistry: Registry? = .none,
        customHostTriple: Triple = hostTriple,
        traitConfiguration: TraitConfiguration = .default,
        pruneDependencies: Bool = false,
        enabledTraitsMap: EnabledTraitsMap = .init()
    ) async throws {
        try fileSystem.createMockToolchain()

        self.sandbox = sandbox
        self.fileSystem = fileSystem
        self.roots = roots
        self.packages = packages
        self.fingerprints = customFingerprints ?? MockPackageFingerprintStorage()
        self.signingEntities = customSigningEntities ?? MockPackageSigningEntityStorage()
        self.mirrors = try customMirrors ?? DependencyMirrors()
        self.identityResolver = DefaultIdentityResolver(
            locationMapper: self.mirrors.effective(for:),
            identityMapper: self.mirrors.effectiveIdentity(for:)
        )
        self.manifestLoader = MockManifestLoader(manifests: [:])
        self.customPackageContainerProvider = customPackageContainerProvider
        self.repositoryProvider = InMemoryGitRepositoryProvider()
        self.checksumAlgorithm = customChecksumAlgorithm ?? MockHashAlgorithm()
        self.registry = MockRegistry(
            filesystem: self.fileSystem,
            identityResolver: self.identityResolver,
            checksumAlgorithm: self.checksumAlgorithm,
            fingerprintStorage: self.fingerprints,
            signingEntityStorage: self.signingEntities
        )
        self.registryClient = customRegistryClient ?? self.registry.registryClient
        self.customToolsVersion = customToolsVersion
        self.skipDependenciesUpdates = skipDependenciesUpdates
        self.sourceControlToRegistryDependencyTransformation = sourceControlToRegistryDependencyTransformation
        self.defaultRegistry = defaultRegistry
        self.customBinaryArtifactsManager = customBinaryArtifactsManager ?? .init(
            httpClient: HTTPClient.mock(fileSystem: fileSystem),
            archiver: MockArchiver()
        )
        self.customPrebuiltsManager = customPrebuiltsManager
        self.customHostToolchain = try UserToolchain.mockHostToolchain(fileSystem, hostTriple: customHostTriple)
        self.traitConfiguration = traitConfiguration
        self.pruneDependencies = pruneDependencies
        self.enabledTraitsMap = enabledTraitsMap
        try await self.create()
    }

    public var rootsDir: AbsolutePath {
        self.sandbox.appending("roots")
    }

    public var packagesDir: AbsolutePath {
        self.sandbox.appending("pkgs")
    }

    public var artifactsDir: AbsolutePath {
        self.sandbox.appending(components: ".build", "artifacts")
    }

    public var workspaceLocation: Workspace.Location? {
        self._workspace?.location
    }

    public func pathToRoot(withName name: String) throws -> AbsolutePath {
        try AbsolutePath(validating: name, relativeTo: self.rootsDir)
    }

    public func pathToPackage(withName name: String) throws -> AbsolutePath {
        try AbsolutePath(validating: name, relativeTo: self.packagesDir)
    }

    private func create() async throws {
        // Remove the sandbox if present.
        if self.fileSystem.exists(self.sandbox) {
            try self.fileSystem.removeFileTree(self.sandbox)
        }

        // Create directories.
        try self.fileSystem.createDirectory(self.sandbox, recursive: true)
        try self.fileSystem.createDirectory(self.rootsDir, recursive: true)
        try self.fileSystem.createDirectory(self.packagesDir, recursive: true)

        var manifests: [MockManifestLoader.Key: Manifest] = [:]

        func create(package: MockPackage, basePath: AbsolutePath, isRoot: Bool) async throws {
            let packagePath: AbsolutePath
            switch package.location {
            case .fileSystem(let path):
                packagePath = basePath.appending(path)
            case .sourceControl(let url):
                if let containerProvider = customPackageContainerProvider {
                    let observability = ObservabilitySystem.makeForTesting()
                    let packageRef = PackageReference(
                        identity: PackageIdentity(url: url),
                        kind: .remoteSourceControl(url)
                    )
                    let container = try await containerProvider.getContainer(
                        for: packageRef,
                        updateStrategy: .never,
                        observabilityScope: observability.topScope
                    )
                    guard let customContainer = container as? CustomPackageContainer else {
                        throw StringError("invalid custom container: \(container)")
                    }
                    packagePath = try customContainer.retrieve(
                        at: Version(versionString: package.versions.first!!),
                        observabilityScope: observability.topScope
                    )
                } else {
                    packagePath = basePath.appending(
                        components: "sourceControl",
                        url.absoluteString.spm_mangledToC99ExtendedIdentifier()
                    )
                }
            case .registry(let identity, _, let metadata):
                packagePath = basePath.appending(
                    components: "registry",
                    identity.description.spm_mangledToC99ExtendedIdentifier()
                )

                // Write registry release metadata if the mock package provided it.
                if let metadata {
                    try self.fileSystem.createDirectory(packagePath, recursive: true)
                    let path = packagePath.appending(component: RegistryReleaseMetadataStorage.fileName)
                    try RegistryReleaseMetadataStorage.save(metadata, to: path, fileSystem: self.fileSystem)
                }
            }

            let packageLocation: String
            let packageKind: PackageReference.Kind
            let packageVersions: [String?] = isRoot ? [nil] : package.versions

            var sourceControlSpecifier: RepositorySpecifier? = nil
            var registryIdentity: PackageIdentity? = nil
            var registryAlternativeURLs: [URL]? = nil

            switch (isRoot, package.location) {
            case (true, _):
                packageLocation = packagePath.pathString
                packageKind = .root(packagePath)
                sourceControlSpecifier = RepositorySpecifier(path: packagePath)
            case (_, .fileSystem(let path)):
                packageLocation = self.packagesDir.appending(path).pathString
                packageKind = .fileSystem(packagePath)
                sourceControlSpecifier = RepositorySpecifier(path: self.packagesDir.appending(path))
            case (_, .sourceControl(let url)):
                packageLocation = url.absoluteString
                packageKind = .remoteSourceControl(url)
                sourceControlSpecifier = RepositorySpecifier(url: url)
            case (_, .registry(let identity, let alternativeURLs, _)):
                packageLocation = identity.description
                packageKind = .registry(identity)
                registryIdentity = identity
                registryAlternativeURLs = alternativeURLs
            }

            // Create modules on disk.
            let packageToolsVersion = package.toolsVersion ?? .current
            if let specifier = sourceControlSpecifier {
                let repository = self.repositoryProvider.specifierMap[specifier] ?? .init(
                    path: packagePath,
                    fs: self.fileSystem
                )
                try writePackageContent(fileSystem: repository, root: .root, toolsVersion: packageToolsVersion)

                let versions = packageVersions.compactMap { $0 }
                if versions.isEmpty {
                    try repository.commit()
                } else {
                    for version in versions {
                        try repository.commit(hash: package.revisionProvider.map { $0(version) })
                        try repository.tag(name: version)
                    }
                }

                self.repositoryProvider.add(specifier: specifier, repository: repository)
            } else if let identity = registryIdentity {
                let source = InMemoryRegistryPackageSource(
                    fileSystem: self.fileSystem,
                    path: packagePath,
                    writeContent: false
                )
                try writePackageContent(
                    fileSystem: source.fileSystem,
                    root: source.path,
                    toolsVersion: packageToolsVersion
                )
                self.registry.addPackage(
                    identity: identity,
                    versions: packageVersions.compactMap { $0 },
                    sourceControlURLs: registryAlternativeURLs ?? [],
                    source: source
                )
            } else {
                throw InternalError("unknown package type")
            }

            for version in packageVersions {
                let v = version.flatMap(Version.init(_:))
                manifests[.init(url: packageLocation, version: v)] = try Manifest.createManifest(
                    displayName: package.name,
                    path: packagePath,
                    packageKind: packageKind,
                    packageIdentity: .plain(package.name.lowercased()),
                    packageLocation: packageLocation,
                    platforms: package.platforms,
                    version: v,
                    toolsVersion: packageToolsVersion,
                    dependencies: package.dependencies.map { try $0.convert(
                        baseURL: self.packagesDir,
                        identityResolver: self.identityResolver
                    ) },
                    products: package.products.map { try ProductDescription(
                        name: $0.name,
                        type: .library(.automatic),
                        targets: $0.modules
                    ) },
                    targets: package.targets.map { try $0.convert(identityResolver: self.identityResolver) },
                    traits: package.traits,
                    pruneDependencies: self.pruneDependencies
                )
            }

            func writePackageContent(fileSystem: FileSystem, root: AbsolutePath, toolsVersion: ToolsVersion) throws {
                let sourcesDir = root.appending("Sources")
                for target in package.targets {
                    let targetDir = sourcesDir.appending(component: target.name)
                    try fileSystem.createDirectory(targetDir, recursive: true)
                    try fileSystem.writeFileContents(targetDir.appending("file.swift"), bytes: "")
                }
                let manifestPath = root.appending(component: Manifest.filename)
                try fileSystem.writeFileContents(manifestPath, bytes: "")
                try ToolsVersionSpecificationWriter.rewriteSpecification(
                    manifestDirectory: root,
                    toolsVersion: toolsVersion,
                    fileSystem: fileSystem
                )
            }
        }

        // Create root packages.
        for package in self.roots {
            try await create(package: package, basePath: self.rootsDir, isRoot: true)
        }

        // Create dependency packages.
        for package in self.packages {
            try await create(package: package, basePath: self.packagesDir, isRoot: false)
        }

        self.manifestLoader = MockManifestLoader(manifests: manifests)
    }

    public func getOrCreateWorkspace() throws -> Workspace {
        if let workspace = self._workspace {
            return workspace
        }

        let workspace = try Workspace._init(
            fileSystem: self.fileSystem,
            environment: .mockEnvironment,
            location: .init(
                scratchDirectory: self.sandbox.appending(".build"),
                editsDirectory: self.sandbox.appending("edits"),
                resolvedVersionsFile: Workspace.DefaultLocations.resolvedVersionsFile(forRootPackage: self.sandbox),
                localConfigurationDirectory: Workspace.DefaultLocations
                    .configurationDirectory(forRootPackage: self.sandbox),
                sharedConfigurationDirectory: self.fileSystem.swiftPMConfigurationDirectory,
                sharedSecurityDirectory: self.fileSystem.swiftPMSecurityDirectory,
                sharedCacheDirectory: self.fileSystem.swiftPMCacheDirectory
            ),
            configuration: .init(
                skipDependenciesUpdates: self.skipDependenciesUpdates,
                prefetchBasedOnResolvedFile: WorkspaceConfiguration.default.prefetchBasedOnResolvedFile,
                shouldCreateMultipleTestProducts: WorkspaceConfiguration.default.shouldCreateMultipleTestProducts,
                createREPLProduct: WorkspaceConfiguration.default.createREPLProduct,
                additionalFileRules: WorkspaceConfiguration.default.additionalFileRules,
                sharedDependenciesCacheEnabled: WorkspaceConfiguration.default.sharedDependenciesCacheEnabled,
                fingerprintCheckingMode: .strict,
                signingEntityCheckingMode: .strict,
                skipSignatureValidation: false,
                sourceControlToRegistryDependencyTransformation: self.sourceControlToRegistryDependencyTransformation,
                defaultRegistry: self.defaultRegistry,
                manifestImportRestrictions: .none,
                usePrebuilts: self.customPrebuiltsManager != nil,
                prebuiltsDownloadURL: nil,
                prebuiltsRootCertPath: nil,
                pruneDependencies: self.pruneDependencies,
                traitConfiguration: self.traitConfiguration
            ),
            customFingerprints: self.fingerprints,
            customMirrors: self.mirrors,
            customToolsVersion: self.customToolsVersion,
            customHostToolchain: self.customHostToolchain,
            customManifestLoader: self.manifestLoader,
            customPackageContainerProvider: self.customPackageContainerProvider,
            customRepositoryProvider: self.repositoryProvider,
            customRegistryClient: self.registryClient,
            customBinaryArtifactsManager: self.customBinaryArtifactsManager,
            customPrebuiltsManager: self.customPrebuiltsManager,
            customIdentityResolver: self.identityResolver,
            customChecksumAlgorithm: self.checksumAlgorithm,
            delegate: self.delegate
        )

        self._workspace = workspace

        return workspace
    }

    private var _workspace: Workspace?

    public func closeWorkspace(resetState: Bool = true, resetResolvedFile: Bool = true) async throws {
        if resetState {
            try await self._workspace?.resetState()
        }
        if resetResolvedFile {
            try self._workspace.map {
                try self.fileSystem.removeFileTree($0.location.resolvedVersionsFile)
            }
        }
        self._workspace = nil
    }

    public func rootPaths(for packages: [String]) throws -> [AbsolutePath] {
        try packages.map { try AbsolutePath(validating: $0, relativeTo: self.rootsDir) }
    }

    public func checkEdit(
        packageIdentity: String,
        path: AbsolutePath? = nil,
        revision: Revision? = nil,
        checkoutBranch: String? = nil,
        _ result: ([Basics.Diagnostic]) -> Void
    ) async {
        let observability = ObservabilitySystem.makeForTesting()
        await observability.topScope.trap {
            let ws = try self.getOrCreateWorkspace()
            await ws.edit(
                packageIdentity: packageIdentity,
                path: path,
                revision: revision,
                checkoutBranch: checkoutBranch,
                observabilityScope: observability.topScope
            )
        }
        result(observability.diagnostics)
    }

    public func checkUnedit(
        packageIdentity: String,
        roots: [String],
        forceRemove: Bool = false,
        _ result: ([Basics.Diagnostic]) -> Void
    ) async {
        let observability = ObservabilitySystem.makeForTesting()
        await observability.topScope.trap {
            let rootInput = try PackageGraphRootInput(
                packages: rootPaths(for: roots),
                traitConfiguration: traitConfiguration
            )
            let ws = try self.getOrCreateWorkspace()
            try await ws.unedit(
                packageIdentity: packageIdentity,
                forceRemove: forceRemove,
                root: rootInput,
                observabilityScope: observability.topScope
            )
        }
        result(observability.diagnostics)
    }

    public func checkResolve(
        pkg: String,
        roots: [String],
        version: TSCUtility.Version,
        _ result: ([Basics.Diagnostic]) -> Void
    ) async {
        let observability = ObservabilitySystem.makeForTesting()
        await observability.topScope.trap {
            let rootInput = try PackageGraphRootInput(
                packages: rootPaths(for: roots),
                traitConfiguration: traitConfiguration
            )
            let workspace = try self.getOrCreateWorkspace()
            try await workspace.resolve(
                packageName: pkg,
                root: rootInput,
                version: version,
                branch: nil,
                revision: nil,
                observabilityScope: observability.topScope
            )
        }
        result(observability.diagnostics)
    }

    public func checkClean(_ result: ([Basics.Diagnostic]) -> Void) {
        let observability = ObservabilitySystem.makeForTesting()
        observability.topScope.trap {
            let workspace = try self.getOrCreateWorkspace()
            workspace.clean(observabilityScope: observability.topScope)
        }
        result(observability.diagnostics)
    }

    public func checkReset(_ result: ([Basics.Diagnostic]) -> Void) async {
        let observability = ObservabilitySystem.makeForTesting()
        await observability.topScope.trap {
            let workspace = try self.getOrCreateWorkspace()
            await workspace.reset(observabilityScope: observability.topScope)
        }
        result(observability.diagnostics)
    }

    public func checkUpdate(
        roots: [String] = [],
        deps: [MockDependency] = [],
        packages: [String] = [],
        _ result: ([Basics.Diagnostic]) -> Void
    ) async throws {
        let dependencies = try deps.map { try $0.convert(
            baseURL: self.packagesDir,
            identityResolver: self.identityResolver
        ) }

        let observability = ObservabilitySystem.makeForTesting()
        await observability.topScope.trap {
            let rootInput = try PackageGraphRootInput(
                packages: rootPaths(for: roots),
                dependencies: dependencies,
                traitConfiguration: traitConfiguration
            )
            let workspace = try self.getOrCreateWorkspace()
            try await workspace.updateDependencies(
                root: rootInput,
                packages: packages,
                observabilityScope: observability.topScope
            )
        }
        result(observability.diagnostics)
    }

    public func checkUpdateDryRun(
        roots: [String] = [],
        deps: [MockDependency] = [],
        _ result: ([(PackageReference, Workspace.PackageStateChange)]?, [Basics.Diagnostic]) -> Void
    ) async throws {
        let dependencies = try deps.map { try $0.convert(
            baseURL: self.packagesDir,
            identityResolver: self.identityResolver
        ) }
        let rootInput = try PackageGraphRootInput(
            packages: rootPaths(for: roots),
            dependencies: dependencies,
            traitConfiguration: traitConfiguration
        )

        let observability = ObservabilitySystem.makeForTesting()
        let changes = await observability.topScope.trap { () -> [(PackageReference, Workspace.PackageStateChange)]? in
            let workspace = try self.getOrCreateWorkspace()
            return try await workspace.updateDependencies(
                root: rootInput,
                dryRun: true,
                observabilityScope: observability.topScope
            )
        } ?? nil
        result(changes, observability.diagnostics)
    }

    public func checkPackageGraph(
        roots: [String] = [],
        deps: [MockDependency],
        _ result: (ModulesGraph, [Basics.Diagnostic]) -> Void
    ) async throws {
        let dependencies = try deps.map { try $0.convert(
            baseURL: self.packagesDir,
            identityResolver: self.identityResolver
        ) }
        try await self.checkPackageGraph(roots: roots, dependencies: dependencies, result)
    }

    public func checkPackageGraph(
        roots: [String] = [],
        dependencies: [PackageDependency] = [],
        forceResolvedVersions: Bool = false,
        expectedSigningEntities: [PackageIdentity: RegistryReleaseMetadata.SigningEntity] = [:],
        _ result: (ModulesGraph, [Basics.Diagnostic]) throws -> Void
    ) async throws {
        let observability = ObservabilitySystem.makeForTesting()
        let rootInput = try PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies, traitConfiguration: traitConfiguration
        )
        let workspace = try self.getOrCreateWorkspace()
        do {
            let graph = try await workspace.loadPackageGraph(
                rootInput: rootInput,
                forceResolvedVersions: forceResolvedVersions,
                expectedSigningEntities: expectedSigningEntities,
                observabilityScope: observability.topScope
            )
            try result(graph, observability.diagnostics)
        } catch {
            // helpful when graph fails to load
            if observability.hasErrorDiagnostics {
                print(observability.diagnostics.map(\.description).joined(separator: "\n"))
            }
            throw error
        }
    }

    public func checkPackageGraphFailure(
        roots: [String] = [],
        deps: [MockDependency],
        _ result: ([Basics.Diagnostic]) -> Void
    ) async throws {
        let dependencies = try deps.map { try $0.convert(
            baseURL: self.packagesDir,
            identityResolver: self.identityResolver
        ) }
        await self.checkPackageGraphFailure(roots: roots, dependencies: dependencies, result)
    }

    public func checkPackageGraphFailure(
        roots: [String] = [],
        dependencies: [PackageDependency] = [],
        forceResolvedVersions: Bool = false,
        _ result: ([Basics.Diagnostic]) -> Void
    ) async {
        let observability = ObservabilitySystem.makeForTesting()
        await observability.topScope.trap {
            let rootInput = try PackageGraphRootInput(
                packages: rootPaths(for: roots),
                dependencies: dependencies,
                traitConfiguration: traitConfiguration
            )
            let workspace = try self.getOrCreateWorkspace()
            try await workspace.loadPackageGraph(
                rootInput: rootInput,
                forceResolvedVersions: forceResolvedVersions,
                observabilityScope: observability.topScope
            )
        }
        result(observability.diagnostics)
    }

    public struct ResolutionPrecomputationResult {
        public let result: Workspace.ResolutionPrecomputationResult
        public let diagnostics: [Basics.Diagnostic]
    }

    public func checkPrecomputeResolution() async throws -> ResolutionPrecomputationResult {
        let observability = ObservabilitySystem.makeForTesting()
        let workspace = try self.getOrCreateWorkspace()
        let resolvedPackagesStore = try workspace.resolvedPackagesStore.load()

        let rootInput = try PackageGraphRootInput(
            packages: rootPaths(for: roots.map(\.name)),
            dependencies: [],
            traitConfiguration: self.traitConfiguration
        )
        let rootManifests = try await workspace.loadRootManifests(
            packages: rootInput.packages,
            observabilityScope: observability.topScope
        )
        let root = try PackageGraphRoot(
            input: rootInput,
            manifests: rootManifests,
            observabilityScope: observability.topScope,
            enabledTraitsMap: workspace.enabledTraitsMap
        )

        let dependencyManifests = try await workspace.loadDependencyManifests(
            root: root,
            observabilityScope: observability.topScope
        )

        let result = try await workspace.precomputeResolution(
            root: root,
            dependencyManifests: dependencyManifests,
            resolvedPackagesStore: resolvedPackagesStore,
            constraints: [],
            observabilityScope: observability.topScope
        )

        return ResolutionPrecomputationResult(result: result, diagnostics: observability.diagnostics)
    }

    public func set(
        resolvedPackages: [PackageReference: CheckoutState] = [:],
        managedDependencies: [AbsolutePath: Workspace.ManagedDependency] = [:],
        managedArtifacts: [Workspace.ManagedArtifact] = []
    ) async throws {
        let resolvedPackages = resolvedPackages.mapValues { checkoutState -> ResolvedPackagesStore.ResolutionState in
            switch checkoutState {
            case .version(let version, let revision):
                return .version(version, revision: revision.identifier)
            case .branch(let name, let revision):
                return .branch(name: name, revision: revision.identifier)
            case .revision(let revision):
                return .revision(revision.identifier)
            }
        }
        try await self.set(
            resolvedPackages: resolvedPackages,
            managedDependencies: managedDependencies,
            managedArtifacts: managedArtifacts
        )
    }

    public func set(
        resolvedPackages: [PackageReference: ResolvedPackagesStore.ResolutionState],
        managedDependencies: [AbsolutePath: Workspace.ManagedDependency] = [:],
        managedArtifacts: [Workspace.ManagedArtifact] = []
    ) async throws {
        let workspace = try self.getOrCreateWorkspace()
        let resolvedPackagesStore = try workspace.resolvedPackagesStore.load()

        for (ref, state) in resolvedPackages {
            resolvedPackagesStore.track(packageRef: ref, state: state)
        }

        for dependency in managedDependencies {
            // copy the package content to expected managed path
            let managedPath = workspace.path(to: dependency.value)
            if managedPath != dependency.key, self.fileSystem.exists(dependency.key) {
                try self.fileSystem.createDirectory(managedPath.parentDirectory, recursive: true)
                try self.fileSystem.copy(from: dependency.key, to: managedPath)
            } else {
                try self.fileSystem.createDirectory(managedPath, recursive: true)
            }
            await workspace.state.add(dependency: dependency.value)
        }

        for artifact in managedArtifacts {
            // create an empty directory representing the artifact
            try self.fileSystem.createDirectory(artifact.path, recursive: true)
            await workspace.state.artifacts.add(artifact)
        }

        try await workspace.state.save()
    }

    public func resetState() async throws {
        let workspace = try self.getOrCreateWorkspace()
        try await workspace.resetState()
    }

    public enum State {
        public enum CheckoutState {
            case version(TSCUtility.Version)
            case revision(String)
            case branch(String)
        }

        case checkout(CheckoutState)
        case registryDownload(TSCUtility.Version)
        case edited(AbsolutePath?)
        case local
        case custom(TSCUtility.Version, AbsolutePath)
    }

    public struct ManagedDependencyResult {
        public let managedDependencies: Workspace.ManagedDependencies

        public init(_ managedDependencies: Workspace.ManagedDependencies) {
            self.managedDependencies = managedDependencies
        }

        public func check(notPresent name: String, file: StaticString = #file, line: UInt = #line) {
            self.check(notPresent: .plain(name), file: file, line: line)
        }

        public func check(notPresent dependencyId: PackageIdentity, file: StaticString = #file, line: UInt = #line) {
            let dependency = self.managedDependencies[dependencyId]
            XCTAssertNil(
                dependency,
                "Unexpectedly found \(dependencyId) in managed dependencies",
                file: file,
                line: line
            )
        }

        public func checkEmpty(file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(self.managedDependencies.count, 0, file: file, line: line)
        }

        public func check(dependency name: String, at state: State, file: StaticString = #file, line: UInt = #line) {
            self.check(dependency: .plain(name), at: state, file: file, line: line)
        }

        public func check(
            dependency dependencyId: PackageIdentity,
            at state: State,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            guard let dependency = managedDependencies[dependencyId] else {
                return XCTFail("\(dependencyId) does not exists", file: file, line: line)
            }
            switch state {
            case .checkout(let checkoutState):
                guard case .sourceControlCheckout(let dependencyCheckoutState) = dependency.state else {
                    return XCTFail("invalid dependency state \(dependency.state)", file: file, line: line)
                }
                switch checkoutState {
                case .version(let version):
                    XCTAssertEqual(dependencyCheckoutState.version, version, file: file, line: line)
                case .revision(let revision):
                    XCTAssertEqual(dependencyCheckoutState.revision.identifier, revision, file: file, line: line)
                case .branch(let branch):
                    XCTAssertEqual(dependencyCheckoutState.branch, branch, file: file, line: line)
                }
            case .registryDownload(let downloadVersion):
                guard case .registryDownload(let dependencyVersion) = dependency.state else {
                    return XCTFail("invalid dependency state \(dependency.state)", file: file, line: line)
                }
                XCTAssertEqual(dependencyVersion, downloadVersion, file: file, line: line)
            case .edited(let path):
                guard case .edited(_, unmanagedPath: path) = dependency.state else {
                    XCTFail("Expected edited dependency; found '\(dependency.state)' instead", file: file, line: line)
                    return
                }
            case .local:
                guard case .fileSystem = dependency.state else {
                    XCTFail("Expected local dependency", file: file, line: line)
                    return
                }
            case .custom(let currentVersion, let currentPath):
                guard case .custom(let version, let path) = dependency.state else {
                    return XCTFail("invalid dependency state \(dependency.state)", file: file, line: line)
                }
                XCTAssertTrue(currentVersion == version && currentPath == path, file: file, line: line)
            }
        }
    }

    public struct ManagedArtifactResult {
        public let managedArtifacts: Workspace.ManagedArtifacts

        public init(_ managedArtifacts: Workspace.ManagedArtifacts) {
            self.managedArtifacts = managedArtifacts
        }

        public func checkNotPresent(
            packageName: String,
            targetName: String,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            self.checkNotPresent(packageIdentity: .plain(packageName), targetName: targetName, file: file, line: line)
        }

        public func checkNotPresent(
            packageIdentity: PackageIdentity,
            targetName: String,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            let artifact = self.managedArtifacts[packageIdentity: packageIdentity, targetName: targetName]
            XCTAssert(
                artifact == nil,
                "Unexpectedly found \(packageIdentity).\(targetName) in managed artifacts",
                file: file,
                line: line
            )
        }

        public func checkEmpty(file: StaticString = #file, line: UInt = #line) {
            XCTAssertEqual(self.managedArtifacts.count, 0, file: file, line: line)
        }

        public func check(
            packageName: String,
            targetName: String,
            source: Workspace.ManagedArtifact.Source,
            path: AbsolutePath,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            self.check(
                packageIdentity: .plain(packageName),
                targetName: targetName,
                source: source,
                path: path,
                file: file,
                line: line
            )
        }

        public func check(
            packageIdentity: PackageIdentity,
            targetName: String,
            source: Workspace.ManagedArtifact.Source,
            path: AbsolutePath,
            file: StaticString = #file,
            line: UInt = #line
        ) {
            guard let artifact = managedArtifacts[packageIdentity: packageIdentity, targetName: targetName] else {
                XCTFail("managed artifact '\(packageIdentity).\(targetName)' does not exists", file: file, line: line)
                return
            }
            XCTAssertEqual(artifact.path, path, file: file, line: line)
            switch (artifact.source, source) {
            case (.remote(let lhsURL, let lhsChecksum), .remote(let rhsURL, let rhsChecksum)):
                XCTAssertEqual(lhsURL, rhsURL, file: file, line: line)
                XCTAssertEqual(lhsChecksum, rhsChecksum, file: file, line: line)
            case (.local(let lhsChecksum), .local(let rhsChecksum)):
                XCTAssertEqual(lhsChecksum, rhsChecksum, file: file, line: line)
            default:
                XCTFail("wrong source type", file: file, line: line)
            }
        }
    }

    public func loadDependencyManifests(
        roots: [String] = [],
        deps: [MockDependency] = [],
        _ result: (Workspace.DependencyManifests, [Basics.Diagnostic]) -> Void
    ) async throws {
        let observability = ObservabilitySystem.makeForTesting()
        let dependencies = try deps.map { try $0.convert(
            baseURL: self.packagesDir,
            identityResolver: self.identityResolver
        ) }
        let workspace = try self.getOrCreateWorkspace()
        let rootInput = try PackageGraphRootInput(
            packages: rootPaths(for: roots), dependencies: dependencies, traitConfiguration: traitConfiguration
        )
        let rootManifests = try await workspace.loadRootManifests(
            packages: rootInput.packages,
            observabilityScope: observability.topScope
        )
        let graphRoot = try PackageGraphRoot(
            input: rootInput,
            manifests: rootManifests,
            observabilityScope: observability.topScope,
            enabledTraitsMap: workspace.enabledTraitsMap
        )
        let manifests = try await workspace.loadDependencyManifests(
            root: graphRoot,
            observabilityScope: observability.topScope
        )
        result(manifests, observability.diagnostics)
    }

    public func checkManagedDependencies(
        file: StaticString = #file,
        line: UInt = #line,
        _ result: (ManagedDependencyResult) throws -> Void
    ) async {
        do {
            let workspace = try self.getOrCreateWorkspace()
            try await result(ManagedDependencyResult(workspace.state.dependencies))
        } catch {
            XCTFail("Failed with error \(error.interpolationDescription)", file: file, line: line)
        }
    }

    public func checkManagedArtifacts(
        file: StaticString = #file,
        line: UInt = #line,
        _ result: (ManagedArtifactResult) throws -> Void
    ) async {
        do {
            let workspace = try self.getOrCreateWorkspace()
            try await result(ManagedArtifactResult(workspace.state.artifacts))
        } catch {
            XCTFail("Failed with error \(error.interpolationDescription)", file: file, line: line)
        }
    }

    public struct ResolvedResult {
        public let store: ResolvedPackagesStore

        public init(_ store: ResolvedPackagesStore) {
            self.store = store
        }

        public func check(notPresent name: String, file: StaticString = #file, line: UInt = #line) {
            XCTAssertFalse(
                self.store.resolvedPackages.keys.contains(where: { $0.description == name }),
                "Unexpectedly found \(name) in Package.resolved",
                file: file,
                line: line
            )
        }

        public func check(dependency package: String, at state: State, file: StaticString = #file, line: UInt = #line) {
            guard let pin = store.resolvedPackages.first(where: { $0.key.description == package })?.value else {
                XCTFail("Pin for \(package) not found", file: file, line: line)
                return
            }
            switch state {
            case .checkout(let checkoutState):
                switch (checkoutState, pin.state) {
                case (.version(let checkoutVersion), .version(let pinVersion, _)):
                    XCTAssertEqual(pinVersion, checkoutVersion, file: file, line: line)
                case (.revision(let checkoutRevision), .revision(let pinRevision)):
                    XCTAssertEqual(checkoutRevision, pinRevision, file: file, line: line)
                case (.branch(let checkoutBranch), .branch(let pinBranch, _)):
                    XCTAssertEqual(checkoutBranch, pinBranch, file: file, line: line)
                default:
                    XCTFail("state dont match \(checkoutState) \(pin.state)", file: file, line: line)
                }
            case .registryDownload(let downloadVersion):
                guard case .version(let pinVersion, _) = pin.state else {
                    return XCTFail("invalid pin state \(pin.state)", file: file, line: line)
                }
                XCTAssertEqual(pinVersion, downloadVersion, file: file, line: line)
            case .edited, .local, .custom:
                XCTFail("Unimplemented", file: file, line: line)
            }
        }

        public func check(dependency package: String, url: String, file: StaticString = #file, line: UInt = #line) {
            guard let pin = store.resolvedPackages.first(where: { $0.key.description == package })?.value else {
                XCTFail("Pin for \(package) not found", file: file, line: line)
                return
            }

            XCTAssertEqual(pin.packageRef.kind, .remoteSourceControl(SourceControlURL(url)), file: file, line: line)
        }
    }

    public func checkResolved(
        file: StaticString = #file,
        line: UInt = #line,
        _ result: (ResolvedResult) throws -> Void
    ) {
        do {
            let workspace = try self.getOrCreateWorkspace()
            try result(ResolvedResult(workspace.resolvedPackagesStore.load()))
        } catch {
            XCTFail("Failed with error \(error.interpolationDescription)", file: file, line: line)
        }
    }
}

public final class MockWorkspaceDelegate: WorkspaceDelegate {
    private let lock = NSLock()
    private var _events = [String]()
    private var _manifest: Manifest?
    private var _manifestLoadingDiagnostics: [Basics.Diagnostic]?

    public init() {}

    public func willUpdateRepository(package: PackageIdentity, repository url: String) {
        self.append("updating repo: \(url)")
    }

    public func didUpdateRepository(package: PackageIdentity, repository url: String, duration: DispatchTimeInterval) {
        self.append("finished updating repo: \(url)")
    }

    public func dependenciesUpToDate() {
        self.append("Everything is already up-to-date")
    }

    public func willFetchPackage(
        package: PackageIdentity,
        packageLocation: String?,
        fetchDetails: PackageFetchDetails
    ) {
        self.append("fetching package: \(packageLocation ?? package.description)")
    }

    public func fetchingPackage(package: PackageIdentity, packageLocation: String?, progress: Int64, total: Int64?) {}

    public func didFetchPackage(
        package: PackageIdentity,
        packageLocation: String?,
        result: Result<PackageFetchDetails, Error>,
        duration: DispatchTimeInterval
    ) {
        self.append("finished fetching package: \(packageLocation ?? package.description)")
    }

    public func willCreateWorkingCopy(package: PackageIdentity, repository url: String, at path: AbsolutePath) {
        self.append("creating working copy for: \(url)")
    }

    public func didCreateWorkingCopy(
        package: PackageIdentity,
        repository url: String,
        at path: AbsolutePath,
        duration: DispatchTimeInterval
    ) {
        self.append("finished creating working copy for: \(url)")
    }

    public func willCheckOut(
        package: PackageIdentity,
        repository url: String,
        revision: String,
        at path: AbsolutePath
    ) {
        self.append("checking out repo: \(url)")
    }

    public func didCheckOut(
        package: PackageIdentity,
        repository url: String,
        revision: String,
        at path: AbsolutePath,
        duration: DispatchTimeInterval
    ) {
        self.append("finished checking out repo: \(url)")
    }

    public func removing(package: PackageIdentity, packageLocation: String?) {
        self.append("removing repo: \(packageLocation ?? package.description)")
    }

    public func willResolveDependencies(reason: WorkspaceResolveReason) {
        self.append("will resolve dependencies")
    }

    public func willLoadManifest(
        packageIdentity: PackageIdentity,
        packagePath: AbsolutePath,
        url: String,
        version: Version?,
        packageKind: PackageReference.Kind
    ) {
        self.append("will load manifest for \(packageKind.displayName) package: \(url) (identity: \(packageIdentity))")
    }

    public func didLoadManifest(
        packageIdentity: PackageIdentity,
        packagePath: AbsolutePath,
        url: String,
        version: Version?,
        packageKind: PackageReference.Kind,
        manifest: Manifest?,
        diagnostics: [Basics.Diagnostic],
        duration: DispatchTimeInterval
    ) {
        self.append("did load manifest for \(packageKind.displayName) package: \(url) (identity: \(packageIdentity))")
        self.lock.withLock {
            self._manifest = manifest
            self._manifestLoadingDiagnostics = diagnostics
        }
    }

    public func willComputeVersion(package: PackageIdentity, location: String) {
        // noop
    }

    public func didComputeVersion(
        package: PackageIdentity,
        location: String,
        version: String,
        duration: DispatchTimeInterval
    ) {
        // noop
    }

    public func resolvedFileChanged() {
        // noop
    }

    public func willDownloadBinaryArtifact(from url: String, fromCache: Bool) {
        self.append("downloading binary artifact package: \(url)")
    }

    public func didDownloadBinaryArtifact(
        from url: String,
        result: Result<(path: AbsolutePath, fromCache: Bool), Error>,
        duration: DispatchTimeInterval
    ) {
        self.append("finished downloading binary artifact package: \(url)")
    }

    public func downloadingBinaryArtifact(from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?) {
        // noop
    }

    public func didDownloadAllBinaryArtifacts() {
        // noop
    }

    public func willDownloadPrebuilt(package: PackageIdentity, from url: String, fromCache: Bool) {
        self.append("downloading package prebuilt: \(url)")
    }

    public func didDownloadPrebuilt(
        package: PackageIdentity,
        from url: String,
        result: Result<(path: AbsolutePath, fromCache: Bool), Error>,
        duration: DispatchTimeInterval
    ) {
        self.append("finished downloading package prebuilt: \(url)")
    }

    public func downloadingPrebuilt(package: PackageIdentity, from url: String, bytesDownloaded: Int64, totalBytesToDownload: Int64?) {
        // noop
    }

    public func didDownloadAllPrebuilts() {
        // noop
    }

    public func willUpdateDependencies() {
        // noop
    }

    public func didUpdateDependencies(duration: DispatchTimeInterval) {
        // noop
    }

    public func willResolveDependencies() {
        // noop
    }

    public func didResolveDependencies(duration: DispatchTimeInterval) {
        // noop
    }

    public func willLoadGraph() {
        // noop
    }

    public func didLoadGraph(duration: DispatchTimeInterval) {
        // noop
    }

    public func willCompileManifest(packageIdentity: PackageIdentity, packageLocation: String) {
        // noop
    }

    public func didCompileManifest(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        duration: DispatchTimeInterval
    ) {
        // noop
    }

    public func willEvaluateManifest(packageIdentity: PackageIdentity, packageLocation: String) {
        // noop
    }

    public func didEvaluateManifest(
        packageIdentity: PackageIdentity,
        packageLocation: String,
        duration: DispatchTimeInterval
    ) {
        // noop
    }

    private func append(_ event: String) {
        self.lock.withLock {
            self._events.append(event)
        }
    }

    public var events: [String] {
        self.lock.withLock {
            self._events
        }
    }

    public func clear() {
        self.lock.withLock {
            self._events = []
        }
    }

    public var manifest: Manifest? {
        self.lock.withLock {
            self._manifest
        }
    }

    public var manifestLoadingDiagnostics: [Basics.Diagnostic]? {
        self.lock.withLock {
            self._manifestLoadingDiagnostics
        }
    }
}

extension CheckoutState {
    public var version: Version? {
        switch self {
        case .revision:
            .none
        case .version(let version, _):
            version
        case .branch:
            .none
        }
    }

    public var branch: String? {
        switch self {
        case .revision:
            .none
        case .version:
            .none
        case .branch(let branch, _):
            branch
        }
    }
}

extension PackageReference.Kind {
    fileprivate var displayName: String {
        switch self {
        case .root:
            "root"
        case .fileSystem:
            "fileSystem"
        case .localSourceControl:
            "localSourceControl"
        case .remoteSourceControl:
            "remoteSourceControl"
        case .registry:
            "registry"
        }
    }
}

extension CheckoutState {
    fileprivate var revision: Revision {
        switch self {
        case .revision(let revision):
            revision
        case .version(_, let revision):
            revision
        case .branch(_, let revision):
            revision
        }
    }
}

extension [Basics.Diagnostic] {
    public var hasErrors: Bool {
        self.contains(where: { $0.severity == .error })
    }

    public var hasWarnings: Bool {
        self.contains(where: { $0.severity == .warning })
    }
}
