{- Functions for compiling and executing exercises.
   Largely centered around constructing GHC commands,
   running those through System.Process and analyzing
   the results.
-}
module Execute where

import           Control.Monad.Reader
import           Data.Maybe           (fromJust, isJust)
import           System.Exit
import           System.FilePath      ((</>))
import           System.IO
import           System.Process

import           DirectoryUtils
import           TerminalUtils
import           Types

-- Specialized to run in any monad IO
createProcess' :: (MonadIO m) =>
  CreateProcess -> m (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
createProcess' = liftIO . createProcess

waitForProcess' :: (MonadIO m) => ProcessHandle -> m ExitCode
waitForProcess' = liftIO . waitForProcess

executeExercise :: ExerciseInfo -> ReaderT ProgramConfig IO ()
executeExercise exInfo@(ExerciseInfo exerciseName _ _ _) = do
  config <- ask
  let (processSpec, genDirPath, genExecutablePath, exFilename) = createExerciseProcess config exInfo
  withDirectory genDirPath $ do
    (_, _, procStdErr, procHandle) <- createProcess' (processSpec { std_out = CreatePipe, std_err = CreatePipe })
    exitCode <- waitForProcess' procHandle
    case exitCode of
      ExitFailure code -> void $ onCompileFailure exFilename procStdErr
      ExitSuccess -> do
        progPutStrLnSuccess $ "Successfully compiled: " ++ exFilename
        progPutStrLn $ "----- Executing file: " ++ exFilename ++ " -----"
        let execSpec = shell genExecutablePath
        (_, _, _, execProcHandle) <- createProcess' execSpec
        void $ waitForProcess' execProcHandle

-- Produces 3 Elements for running our exercise:
-- 1. The 'CreateProcess' that we can run for the compilation.
-- 2. The directory path for the generated files
-- 3. The path of the executable we would run (assuming the exercise is executable).
createExerciseProcess :: ProgramConfig -> ExerciseInfo -> (CreateProcess, FilePath, FilePath, FilePath)
createExerciseProcess config (ExerciseInfo exerciseName exDirectory exType _) =
  (processSpec, genDirPath, genExecutablePath, haskellFileName exerciseName)
  where
    exIsRunnable = exType /= CompileOnly
    exFilename = haskellFileName exerciseName
    root = projectRoot config
    fullSourcePath = root </> exercisesExt config </> exDirectory </> exFilename
    genDirPath = root </> "generated_files" </> exDirectory
    genExecutablePath = genDirPath </> haskellModuleName exFilename
    baseArgs = [fullSourcePath, "-odir", genDirPath, "-hidir", genDirPath]
    execArgs = if exIsRunnable then baseArgs ++ ["-o", genExecutablePath] else baseArgs
    finalArgs = execArgs ++ ["-package-db", packageDb config]
    processSpec = proc (ghcPath config) finalArgs

onCompileFailure :: String -> Maybe Handle -> ReaderT ProgramConfig IO RunResult
onCompileFailure exFilename errHandle = withTerminalFailure $ do
  progPutStrLn $ "Couldn't compile : " ++ exFilename
  case errHandle of
    Nothing -> return ()
    Just h  -> lift (hGetContents h) >>= progPutStrLn
  return CompileError

runUnitTestExercise :: FilePath -> String -> ReaderT ProgramConfig IO RunResult
runUnitTestExercise genExecutablePath exFilename = do
  let execSpec = shell genExecutablePath
  (_, execStdOut, execStdErr, execProcHandle) <- createProcess' (execSpec { std_out = CreatePipe, std_err = CreatePipe })
  execExit <- waitForProcess' execProcHandle
  case execExit of
    ExitFailure code -> withTerminalFailure $ do
      progPutStrLn $ "Tests failed on exercise : " ++ exFilename
      case execStdErr of
        Nothing -> return ()
        Just h  -> lift (hGetContents h) >>= progPutStrLn
      case execStdOut of
        Nothing -> return ()
        Just h  -> lift (hGetContents h) >>= progPutStrLn
      return TestFailed
    ExitSuccess -> do
      progPutStrLnSuccess $ "Successfully ran : " ++ exFilename
      return RunSuccess

runExecutableExercise
  :: FilePath
  -> String
  -> [String]
  -> ([String] -> Bool)
  -> ReaderT ProgramConfig IO RunResult
runExecutableExercise genExecutablePath exFilename inputs outputPred = do
  let execSpec = shell genExecutablePath
  (execStdIn, execStdOut, execStdErr, execProcHandle) <- createProcess'
    (execSpec { std_out = CreatePipe, std_err = CreatePipe, std_in = CreatePipe })
  when (isJust execStdIn) $ forM_ inputs $ \i -> lift $ hPutStrLn (fromJust execStdIn) i
  execExit <- waitForProcess' execProcHandle
  case execExit of
    ExitFailure code -> withTerminalFailure $ do
      progPutStrLn $ "Encountered error running exercise: " ++ exFilename
      case execStdOut of
        Nothing -> return ()
        Just h  -> lift (hGetContents h) >>= progPutStrLn
      case execStdErr of
        Nothing -> return ()
        Just h  -> lift (hGetContents h) >>= progPutStrLn
      progPutStrLn "Check the Sample Input and Sample Output in the file."
      progPutStrLn $ "Then try running it for yourself with 'haskellings exec" ++ haskellModuleName exFilename ++ "'."
      return TestFailed
    ExitSuccess -> do
      passes <- case execStdOut of
        Nothing -> return (outputPred [])
        Just h  -> (lines <$> lift (hGetContents h)) >>= (return . outputPred)
      if passes
        then withTerminalSuccess $ do
          progPutStrLn $ "Successfully ran : " ++ exFilename
          progPutStrLn $ "You can run this code for yourself with 'haskellings exec " ++ haskellModuleName exFilename ++ "'."
          return RunSuccess
        else withTerminalFailure $ do
          progPutStrLn $ "Unexpected output for exercise: " ++ exFilename
          progPutStrLn "Check the Sample Input and Sample Output in the file."
          progPutStrLn $ "Then try running it for yourself with 'haskellings exec " ++ haskellModuleName exFilename ++ "'."
          return TestFailed

compileAndRunExercise :: ExerciseInfo -> ReaderT ProgramConfig IO RunResult
compileAndRunExercise exInfo@(ExerciseInfo exerciseName exDirectory exType _) = do
  config <- ask
  let (processSpec, genDirPath, genExecutablePath, exFilename) = createExerciseProcess config exInfo
  withDirectory genDirPath $ do
    (_, _, procStdErr, procHandle) <- createProcess' (processSpec { std_out = CreatePipe, std_err = CreatePipe })
    exitCode <- waitForProcess' procHandle
    case exitCode of
      ExitFailure code -> onCompileFailure exFilename procStdErr
      ExitSuccess -> do
        progPutStrLnSuccess $ "Successfully compiled : " ++ exFilename
        case exType of
          CompileOnly -> return RunSuccess
          UnitTests -> runUnitTestExercise genExecutablePath exFilename
          Executable inputs outputPred -> runExecutableExercise genExecutablePath exFilename inputs outputPred

compileAndRunExercise_ :: ExerciseInfo -> ReaderT ProgramConfig IO ()
compileAndRunExercise_ ex = void $ compileAndRunExercise ex
